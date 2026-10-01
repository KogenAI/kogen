#!/usr/bin/env python3
"""Kogen process-custody supervisor, generalised from the supervisor that
`Kogen.Build.VerificationRunner` has embedded since 7ed41f66.

Invoked as `process_supervisor.py '<json spec>'`. The supervisor never joins
the child's process group: it starts the child in a new session
(`start_new_session=True`, so the child's pid is also its pgid), records the
child's pid/pgid/start time to `spec["register_path"]` as soon as the child is
running, and stays outside the group for the whole run so a later `killpg` on
the child's group never touches the supervisor itself (a real bug found and
fixed while probing this: a supervisor that `setsid()`s itself and then kills
its own group kills itself before reaching the target).

Two duties beyond running the command:
- Parent-death watchdog: a background thread polls whether
  `spec["controller_pid"]` is still alive and this supervisor still has its
  original parent (it is reparented when the controller's port process
  dies). When either is gone, the child's group
  is sent SIGTERM, then SIGKILL after `spec["grace"]` seconds, and the
  supervisor exits. This is what reaps a Developer, Reviewer, Expert, Jev or
  target process when the Kogen controller is killed with Ctrl-C, SIGHUP,
  SIGTERM, `kill -9` or a crash, even though none of those let controller
  Elixir code run to completion.
- Temporary prompt file removal: `spec["stdin_path"]`, when given, is removed
  once the child has ended (normally or via the watchdog).

Two IO modes:
- `"batch"` (default): the child's stdout+stderr are redirected to
  `spec["log"]`; the child's stdin comes from `spec["stdin_path"]`, an
  anonymous pipe when `stdin_size` is supplied, or is closed. Input bytes
  arrive only through the supervisor's stdin, never the spec or files.
  The supervisor's own stdout carries exactly one line of JSON facts
  at the end, matching `VerificationRunner`'s existing contract.
- `"passthrough"`: the child inherits the supervisor's own stdio verbatim (so
  a caller that itself piped a Port's stdio through to this supervisor gets a
  transparent relay, for protocols that need live bidirectional stdio, such
  as Jev's executable transport). Final facts go to `spec["report_path"]`
  instead of stdout, since stdout is the data channel.
"""

import datetime
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time


def now():
    value = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
    return value.replace("+00:00", "Z")


def alive(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def settle(group, grace):
    deadline = time.monotonic() + grace
    while alive(group) and time.monotonic() < deadline:
        time.sleep(0.05)
    return not alive(group)


def signal_group(group, number):
    try:
        os.killpg(group, number)
    except (ProcessLookupError, PermissionError):
        pass


def lstart(pid):
    try:
        out = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            capture_output=True, text=True, check=False,
        )
        return out.stdout.strip()
    except OSError:
        return ""


def controller_alive(pid):
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def forward_stdin(child, size, result):
    try:
        data = sys.stdin.buffer.read(size)
        if len(data) != size:
            raise EOFError("anonymous stdin ended early")
        child.stdin.write(data)
        child.stdin.flush()
    except (OSError, ValueError, EOFError):
        result["error"] = "anonymous stdin transfer failed"
    finally:
        try:
            child.stdin.close()
        except OSError:
            result["error"] = "anonymous stdin close failed"


def main():
    spec = json.loads(sys.argv[1])
    mode = spec.get("mode", "batch")
    controller_pid = spec.get("controller_pid")
    poll = spec.get("poll", 0.2)
    grace = spec.get("grace", 2.0)
    timeout = spec.get("timeout")
    soft_timeout = bool(spec.get("soft_timeout"))
    # A soft time-box is held (never a stop, never an interrupt) until the
    # turn's session identity appears in the log, so the nudge can resume it.
    ready_pattern = spec.get("soft_ready_pattern")
    ready_re = re.compile(ready_pattern.encode()) if ready_pattern else None

    started = now()
    clock = time.monotonic()
    timed_out = False
    watchdog_reaped = False
    spawn_error = None
    code = 1
    cleanup = "clean"

    stop_watchdog = threading.Event()
    child_holder = {}
    # The supervisor's own parent is the controller's port process; when it
    # dies this process is reparented (to 1 on macOS), which a reused
    # controller pid cannot mask.
    parent = os.getppid()

    def session_seen():
        try:
            with open(spec["log"], "rb") as handle:
                return ready_re.search(handle.read(4 * 1024 * 1024)) is not None
        except OSError:
            return False

    def watchdog():
        deadline = clock + timeout if timeout else None
        while not stop_watchdog.is_set():
            time.sleep(poll)
            if "child" not in child_holder:
                continue
            if deadline and time.monotonic() >= deadline:
                if soft_timeout and ready_re and not session_seen():
                    continue
                # `timed_out` is set before any signal so the supervisor never
                # reports a soft-stopped child as an ordinary exit.
                child_holder["timed_out"] = True
                if soft_timeout:
                    # Developer turn time-box: TERM only the Developer process
                    # (never its group, so native helper children are not
                    # reaped) lets the CLI persist its session, then KILL that
                    # process alone after the grace.
                    proc = child_holder["child"]
                    try:
                        os.kill(proc.pid, signal.SIGTERM)
                    except (ProcessLookupError, PermissionError):
                        pass
                    end = time.monotonic() + grace
                    while proc.poll() is None and time.monotonic() < end:
                        time.sleep(0.05)
                    if proc.poll() is None:
                        try:
                            os.kill(proc.pid, signal.SIGKILL)
                        except (ProcessLookupError, PermissionError):
                            pass
                else:
                    signal_group(child_holder["child"].pid, signal.SIGKILL)
                return
            if os.getppid() != parent or not controller_alive(controller_pid):
                child_holder["watchdog_reaped"] = True
                signal_group(child_holder["child"].pid, signal.SIGTERM)
                if not settle(child_holder["child"].pid, grace):
                    signal_group(child_holder["child"].pid, signal.SIGKILL)
                return

    watcher = threading.Thread(target=watchdog, daemon=True)
    watcher.start()

    log_file = None
    stdin_file = None
    input_thread = None
    input_result = {}
    try:
        if mode == "passthrough":
            stdout_target = None
            stderr_target = None
            stdin_target = None
        else:
            log_file = open(spec["log"], "xb")
            stdout_target = log_file
            stderr_target = subprocess.STDOUT
            if spec.get("stdin_size") is not None:
                size = spec["stdin_size"]
                if not isinstance(size, int) or not 0 <= size <= 16384 or spec.get("stdin_path"):
                    raise ValueError("invalid anonymous stdin specification")
                stdin_target = subprocess.PIPE
            elif spec.get("stdin_path"):
                stdin_file = open(spec["stdin_path"], "rb")
                stdin_target = stdin_file
            else:
                stdin_target = subprocess.DEVNULL

        env = spec.get("env")
        try:
            child = subprocess.Popen(
                spec["argv"], cwd=spec.get("cwd"), stdin=stdin_target,
                stdout=stdout_target, stderr=stderr_target,
                start_new_session=True, env=env,
            )
        except OSError as error:
            spawn_error = str(error)
            if log_file:
                log_file.write(("Kogen could not start command: %s\n" % error).encode())
        else:
            child_holder["child"] = child
            if spec.get("stdin_size") is not None:
                input_thread = threading.Thread(
                    target=forward_stdin, args=(child, spec["stdin_size"], input_result), daemon=True
                )
                input_thread.start()
            pgid = child.pid
            if spec.get("register_path"):
                registration = {"pid": child.pid, "pgid": pgid, "started_at": lstart(child.pid)}
                tmp = spec["register_path"] + ".tmp"
                with open(tmp, "w") as handle:
                    json.dump(registration, handle)
                os.replace(tmp, spec["register_path"])

            code = child.wait()
            if input_thread:
                input_thread.join(timeout=1.0)
                if input_thread.is_alive():
                    input_result["error"] = "anonymous stdin transfer did not settle"
                if input_result.get("error"):
                    code = 1
            if code < 0:
                code = 128 - code
            timed_out = bool(child_holder.get("timed_out"))
            watchdog_reaped = bool(child_holder.get("watchdog_reaped"))

            if timed_out and soft_timeout:
                # Helpers the Developer left running finish within the grace
                # before any group reap.
                settle(pgid, grace)

            if alive(pgid):
                cleanup = "terminated"
                signal_group(pgid, signal.SIGTERM)
                if not settle(pgid, grace):
                    signal_group(pgid, signal.SIGKILL)
                    if not settle(pgid, grace):
                        cleanup = "failed"
    finally:
        stop_watchdog.set()
        if stdin_file:
            stdin_file.close()
        if log_file:
            log_file.close()
        if spec.get("stdin_path") and spec.get("remove_stdin", True):
            try:
                os.remove(spec["stdin_path"])
            except OSError:
                pass
        if spec.get("tmp_dir"):
            import shutil
            shutil.rmtree(spec["tmp_dir"], ignore_errors=True)

    finished = now()
    facts = {
        "exit_code": code,
        "cleanup": cleanup,
        "timed_out": timed_out,
        "watchdog_reaped": watchdog_reaped,
        "spawn_error": spawn_error,
        "stdin_error": input_result.get("error"),
        "started_at": started,
        "finished_at": finished,
        "elapsed_ms": int((time.monotonic() - clock) * 1000),
        "pid": child_holder["child"].pid if "child" in child_holder else None,
        "pgid": child_holder["child"].pid if "child" in child_holder else None,
    }

    if mode == "passthrough" and spec.get("report_path"):
        tmp = spec["report_path"] + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(facts, handle)
        os.replace(tmp, spec["report_path"])
    else:
        print(json.dumps(facts))


if __name__ == "__main__":
    main()
