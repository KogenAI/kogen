#!/usr/bin/env python3
"""Own one isolated test process group until all of its work is finished."""
from pathlib import Path
import os
import select
import shutil
import signal
import subprocess
import sys
import time
import base64


def report(message):
    """A dead BEAM port must not interrupt the supervisor's final cleanup."""
    try:
        print(message, flush=True)
    except BrokenPipeError:
        # The parent worker can die while this supervisor is reaping its VM.
        # Redirect final interpreter flushing as well as later reports.
        sys.stdout = open(os.devnull, "w")


def group_owned(process):
    """The unreaped child reserves its PID even after it becomes a zombie."""
    if process.returncode is not None:
        return False
    try:
        os.kill(process.pid, 0)
        try:
            return os.getpgid(process.pid) == process.pid
        except ProcessLookupError:
            # macOS hides a zombie's PGID, but its unreaped PID cannot have
            # been reused by an unrelated group.
            return True
    except OSError:
        return False


def kill_group(process, sig):
    if not group_owned(process):
        return
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # An orphan being reaped may briefly reject signals on macOS. The
        # mandatory wait_group check still requires the group to disappear.
        pass


def wait_group(pid):
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            # macOS can report EPERM while launchd is reaping an orphaned
            # member. Continue waiting for confirmed group disappearance.
            pass
        time.sleep(0.005)
    raise RuntimeError(f"isolated process group {pid} survived cleanup")


class ExitObserver:
    """Notice child exit without releasing its PID before group cleanup."""

    def __init__(self, process):
        self.process = process
        self.exited = False
        self.queue = None
        if hasattr(select, "kqueue"):
            self.queue = select.kqueue()
            try:
                self.queue.control([
                    select.kevent(process.pid, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
                                  fflags=select.KQ_NOTE_EXIT)
                ], 0, 0)
            except ProcessLookupError:
                # The child exited before registration. It remains unreaped.
                self.exited = True

    def poll(self):
        if self.exited:
            return True
        if self.queue is not None:
            self.exited = bool(self.queue.control(None, 1, 0))
        elif hasattr(os, "waitid"):
            self.exited = os.waitid(os.P_PID, self.process.pid,
                                    os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        else:
            # Older platforms without either non-reaping observer retain the
            # previous fail-closed behavior: group_owned refuses a reaped PID.
            self.exited = self.process.poll() is not None
        return self.exited

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.poll():
                return True
            time.sleep(0.005)
        return self.poll()

    def close(self):
        if self.queue is not None:
            self.queue.close()


def settle_group(process, observer):
    """Bound both waits, including the wait after an unsuccessful group kill.

    A group signal can be refused while macOS reaps an orphan. The subsequent
    group probe decides whether cleanup passed; the launcher must never wait
    forever for a leader it could not signal.
    """
    kill_group(process, signal.SIGTERM)
    observer.wait(0.2)
    # The original PID is still reserved here, including when the leader
    # exited naturally. Kill its orphaned group members before wait() reaps it.
    kill_group(process, signal.SIGKILL)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"isolated child {process.pid} survived bounded group cleanup"
        ) from error
    wait_group(process.pid)


def descendants(pid):
    table = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
    children = {}
    infrastructure = set()
    for row in table.splitlines():
        child, parent, command = row.split(maxsplit=2)
        child, parent = int(child), int(parent)
        children.setdefault(parent, []).append(child)
        if Path(command).name in ("erl_child_setup", "inet_gethost"):
            infrastructure.add(child)

    def walk(parent):
        result = []
        for child in children.get(parent, []):
            result.extend(walk(child))
            if child not in infrastructure:
                result.append(child)
        return result
    return walk(pid)


def reap_descendants(pid):
    # Erlang gives spawned ports their own sessions. A process-group kill alone
    # cannot reach them. Keep the VM alive to reap its ports before stopping it.
    owned = descendants(pid)
    for child in dict.fromkeys(owned):
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            continue
        deadline = time.monotonic() + 0.2
        while time.monotonic() < deadline:
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.005)
        else:
            raise RuntimeError(f"isolated descendant {child} survived cleanup")


def main():
    profile = os.environ.get("KOGEN_PROFILE_ISOLATED") == "1"
    started = time.monotonic()
    timeout = float(sys.argv[1])
    startup_timeout = float(sys.argv[2])
    readiness = None if sys.argv[3] == "-" else Path(sys.argv[3])
    result = Path(os.environ["KOGEN_ISOLATED_RESULT"])
    # Establish ownership before creating any child. The parent checks this
    # marker only after confirmed launcher exit, never while we are running.
    (result.parent / "supervisor-started").touch()
    try:
        process = subprocess.Popen(sys.argv[4:], stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        shutil.rmtree(result.parent)
        raise
    observer = ExitObserver(process)
    deadline = None if readiness else time.monotonic() + timeout
    launched = time.monotonic()
    startup_deadline = time.monotonic() + startup_timeout if readiness else None
    status = 124
    completed = False
    try:
        while not observer.poll():
            if readiness and deadline is None:
                if readiness.is_file():
                    report("KOGEN_ISOLATED_READY")
                    deadline = time.monotonic() + timeout
                elif time.monotonic() >= startup_deadline:
                    status = 126
                    break

            if result.exists():
                if result.is_symlink() or not result.is_file():
                    raise RuntimeError("isolated completion receipt is not a regular file")
                fields = result.read_text().splitlines()
                if len(fields) != 6:
                    raise RuntimeError("isolated completion receipt shape is invalid")
                version, invocation, source64, selector64, status_text, completed = fields
                source = base64.b64decode(source64, validate=True).decode()
                selector = base64.b64decode(selector64, validate=True).decode()
                if (version != "1" or
                        invocation != os.environ["KOGEN_ISOLATED_INVOCATION"] or
                        source != os.environ["KOGEN_ISOLATED_SOURCE"] or
                        selector != os.environ["KOGEN_ISOLATED_SELECTOR"] or
                        completed != "true"):
                    raise RuntimeError("isolated completion receipt binding mismatch")
                try:
                    status = int(status_text)
                except ValueError:
                    raise RuntimeError("isolated completion receipt status is invalid")
                completed = True
                break
            if deadline is None:
                remaining = startup_deadline - time.monotonic()
            else:
                remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            # Port closure (including an ExUnit timeout) cancels this owner too.
            readable, _, _ = select.select([sys.stdin], [], [], min(remaining, 0.02))
            if readable:
                os.read(sys.stdin.fileno(), 1)
                break
        else:
            # Read the exit status only after owned group members are reaped.
            status = None
    finally:
        # Also remove background work on normal/nonzero exit. Descendants remain
        # in this session even after the initial VM exits.
        cleanup_error = None
        scan_started = time.monotonic()
        try:
            reap_descendants(process.pid)
        except (OSError, RuntimeError) as error:
            cleanup_error = error
        scanned = time.monotonic()
        if completed and cleanup_error is None:
            # Let BEAM shut down its own runtime helpers normally. Killing
            # erl_child_setup first makes BEAM crash and write a crash dump.
            result.with_suffix(".ack").touch()
            if not observer.wait(1):
                status = 125
        settle_group(process, observer)
        observer.close()
        settled = time.monotonic()
        if status is None or (completed and process.returncode != status):
            status = process.returncode
        if cleanup_error:
            raise cleanup_error
        if not result.parent.is_dir():
            raise RuntimeError("private fixture disappeared before child cleanup completed")
        report("isolated children terminated; private fixture still present")
        try:
            shutil.rmtree(result.parent)
        except OSError as error:
            raise RuntimeError(f"could not remove private fixture {result.parent}: {error}") from error
        if completed:
            if profile:
                report("KOGEN_ISOLATED_TIMING\t" + str({
                    "launch_ms": round((launched - started) * 1000),
                    "to_receipt_ms": round((scan_started - launched) * 1000),
                    "scan_ms": round((scanned - scan_started) * 1000),
                    "settle_ms": round((settled - scanned) * 1000),
                    "total_ms": round((time.monotonic() - started) * 1000),
                }))
            report("KOGEN_ISOLATED_COMPLETION\t" + "\t".join(fields + ["passed"]))
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
