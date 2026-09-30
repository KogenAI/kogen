#!/usr/bin/env python3
"""Bounded, read-only native account discovery through `codex app-server`.

Production adaptation of the 2026-09-29 plugin-isolation probe. The caller
(Kogen.Codex.AccountObservation) supplies one JSON spec as argv[1]:

    {"executable": ..., "args": [...], "cwd": ..., "init_timeout": s,
     "request_timeout": s}

`args` are the exact effective launch arguments (the caller's own flags
decide apps/plugins); this driver appends only `app-server --stdio`. The
environment (CODEX_HOME and the rest of the launch context) is inherited
from the caller, except that CODEX_HOME is replaced by a disposable copy
of the scope's auth.json and config.toml (see main). No model turn and no app or MCP tool call is
made: only initialize, app/list, app/installed, plugin/installed and
account/read (never refreshing a token). The server runs in its own session
and its whole process group is terminated when the driver finishes. Secrets
are dropped from every recorded response; the account object is recorded
only as a SHA-256 fingerprint. The result JSON is written to stdout.
"""

import hashlib
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import threading

SECRET_WORDS = ("token", "secret", "email", "authorization", "credential", "headers")
CLEANUP_GRACE_SECONDS = 3


def group_quiescent(pgid):
    """Return false while a live process remains in the owned group."""
    try:
        listing = subprocess.run(
            ["ps", "-eo", "pid=,pgid=,stat="],
            text=True,
            capture_output=True,
            timeout=1,
            check=True,
        ).stdout.splitlines()
        return not any(
            len(fields := line.split()) >= 3
            and int(fields[1]) == pgid
            and "Z" not in fields[2]
            for line in listing
        )
    except (OSError, subprocess.SubprocessError, ValueError):
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        return False


def cleanup_group(proc):
    """Escalate for the full group even when its leader exits first."""
    attempts = []
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        attempts.append("SIGTERM")
    except ProcessLookupError:
        pass
    except OSError as error:
        attempts.append("SIGTERM failed: " + str(error))

    deadline = time.monotonic() + CLEANUP_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            proc.wait(timeout=0.05)
        except subprocess.TimeoutExpired:
            pass
        if proc.poll() is not None and group_quiescent(proc.pid):
            return True, attempts
        time.sleep(0.05)

    try:
        os.killpg(proc.pid, signal.SIGKILL)
        attempts.append("SIGKILL")
    except ProcessLookupError:
        pass
    except OSError as error:
        attempts.append("SIGKILL failed: " + str(error))

    kill_deadline = time.monotonic() + 1
    while time.monotonic() < kill_deadline:
        try:
            proc.wait(timeout=0.05)
        except subprocess.TimeoutExpired:
            pass
        if proc.poll() is not None and group_quiescent(proc.pid):
            return True, attempts
        time.sleep(0.05)
    return False, attempts


def clean(value):
    if isinstance(value, dict):
        return {
            k: clean(v)
            for k, v in value.items()
            if not any(word in k.lower() for word in SECRET_WORDS)
        }
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value


def observe(report_home=None):
    spec = json.loads(sys.argv[1])
    argv = [spec["executable"], *spec["args"], "app-server", "--stdio"]
    out = {"model_turns": 0, "tool_calls": 0, "responses": {}}
    cancelled = threading.Event()
    parent_pid = os.getppid()
    stop_parent_watch = threading.Event()
    interrupted_by = []

    def interrupt(sig, _frame):
        interrupted_by.append(signal.Signals(sig).name)
        cancelled.set()

    previous_handlers = {
        sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)
    }

    try:
        proc = subprocess.Popen(
            argv,
            cwd=spec["cwd"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as error:
        out["error"] = f"launch failed: {error}"
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        print(json.dumps(out))
        return

    def watch_parent():
        while not stop_parent_watch.wait(0.1):
            if os.getppid() != parent_pid:
                out["parent_lost"] = True
                cancelled.set()
                return

    parent_watch = threading.Thread(target=watch_parent, daemon=True)
    parent_watch.start()
    buffer = b""
    counter = 0

    def send(method, params):
        nonlocal counter
        counter += 1
        message = {"id": counter, "method": method, "params": params}
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()
        return counter

    def read_until(ids, timeout):
        nonlocal buffer
        due = time.monotonic() + timeout
        got = {}
        while time.monotonic() < due and set(got) != set(ids):
            if cancelled.is_set():
                raise InterruptedError("observation driver cancelled")
            remaining = min(0.1, max(0, due - time.monotonic()))
            ready = select.select([proc.stdout], [], [], remaining)[0]
            if not ready:
                continue
            chunk = os.read(proc.stdout.fileno(), 1048576)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    reply = json.loads(line)
                except ValueError:
                    continue
                if reply.get("id") in ids and ("result" in reply or "error" in reply):
                    got[reply["id"]] = reply
        if cancelled.is_set():
            raise InterruptedError("observation driver cancelled")
        return got

    try:
        init = send(
            "initialize",
            {
                "clientInfo": {"name": "kogen_account_observation", "version": "1"},
                "capabilities": {"experimentalApi": True},
            },
        )
        out["initialize"] = clean(read_until([init], spec["init_timeout"]).get(init, {"timeout": True}))
        if report_home:
            result = out["initialize"].get("result")
            reported = result.get("codexHome") if isinstance(result, dict) else None
            if isinstance(reported, str) and os.path.realpath(reported) == os.path.realpath(
                report_home[0]
            ):
                result["codexHome"] = report_home[1]
        proc.stdin.write(b'{"method":"initialized"}\n')
        proc.stdin.flush()
        requests = {
            send("app/list", {"forceRefetch": True, "limit": 100}): "apps",
            send("app/installed", {"forceRefresh": True}): "installed_apps",
            send("plugin/installed", {"cwds": [spec["cwd"]]}): "installed_plugins",
            send("account/read", {"refreshToken": False}): "account",
        }
        got = read_until(requests, spec["request_timeout"])
        for request_id, name in requests.items():
            reply = got.get(request_id, {"timeout": True})
            if name == "account":
                raw = reply.get("result", {}).get("account") if isinstance(reply.get("result"), dict) else None
                out["account_fingerprint"] = (
                    hashlib.sha256(json.dumps(raw, sort_keys=True).encode()).hexdigest() if raw else None
                )
            else:
                out["responses"][name] = clean(reply)
    except Exception as error:  # recorded, never hidden
        out["error"] = str(error)
    finally:
        stop_parent_watch.set()
        parent_watch.join(timeout=1)
        cleanup_ok, attempts = cleanup_group(proc)
        out["cleanup"] = {"ok": cleanup_ok, "attempts": attempts}
        if not cleanup_ok:
            out["error"] = "app-server process group cleanup failed"
        if interrupted_by:
            out["interrupted_by"] = interrupted_by[-1]
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)

    print(json.dumps(out))
    return 0 if out.get("cleanup", {"ok": True})["ok"] else 1


# What the observer needs from the credential scope: the account identity
# (auth.json) and the native settings it reports on (config.toml).
SCOPE_INPUTS = ("auth.json", "config.toml")


def main():
    scope = os.environ.get("CODEX_HOME")
    if not scope:
        return observe()
    # Codex with plugins enabled creates plugins/ in its home. Run it in a
    # disposable home holding copies of the scope inputs so the shared scope
    # is only ever read. The server-reported home is mapped back to the real
    # scope only when it is exactly the disposable one.
    disposable = tempfile.mkdtemp(prefix="kogen-observer-")
    try:
        for name in SCOPE_INPUTS:
            source = os.path.join(scope, name)
            if os.path.isfile(source) and not os.path.islink(source):
                shutil.copyfile(source, os.path.join(disposable, name))
                os.chmod(os.path.join(disposable, name), 0o600)
        os.environ["CODEX_HOME"] = disposable
        return observe(report_home=(disposable, scope))
    finally:
        shutil.rmtree(disposable, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
