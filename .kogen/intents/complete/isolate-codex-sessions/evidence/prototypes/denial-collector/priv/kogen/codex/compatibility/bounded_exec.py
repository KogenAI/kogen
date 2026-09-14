#!/usr/bin/env python3
"""Bound candidate provider work; stdin/stdout remain native protocol streams."""
import json
import os
import signal
import subprocess
import sys
import threading

import time


def seconds(name, default):
    try:
        return max(0.1, float(os.environ.get(name, default)))
    except ValueError:
        return default


def group_empty(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def group_quiescent(pid):
    """A killed grandchild can remain a zombie while init reaps it."""
    try:
        listing = subprocess.run(
            ["ps", "-eo", "pid=,pgid=,stat="], text=True, capture_output=True, timeout=1, check=True
        ).stdout.splitlines()
        for line in listing:
            fields = line.split()
            if len(fields) >= 3 and int(fields[1]) == pid and "Z" not in fields[2]:
                return False
        return True
    except (OSError, subprocess.SubprocessError, ValueError):
        return group_empty(pid)


def signal_owned(process, sig, attempts):
    label = signal.Signals(sig).name
    try:
        os.killpg(process.pid, sig)
        attempts.append({"signal": label, "target": "group", "outcome": "sent"})
        return True
    except (PermissionError, ProcessLookupError, OSError) as error:
        attempts.append({"signal": label, "target": "group", "outcome": "failed", "error": str(error)})
    if process.poll() is not None:
        attempts.append({"signal": label, "target": "child", "outcome": "not_needed"})
        return True
    try:
        process.send_signal(sig)
        attempts.append({"signal": label, "target": "child", "outcome": "sent"})
        return True
    except (PermissionError, ProcessLookupError, OSError) as error:
        attempts.append({"signal": label, "target": "child", "outcome": "failed", "error": str(error)})
        return False


def cleanup(process, deadline, attempts):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        signal_owned(process, sig, attempts)
        signal_deadline = deadline if sig == signal.SIGKILL else min(deadline, time.monotonic() + max(0.1, (deadline - time.monotonic()) / 2))
        while time.monotonic() < signal_deadline:
            try:
                process.wait(timeout=min(0.05, max(0.001, deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                pass
            if process.poll() is not None and group_quiescent(process.pid):
                return True
    attempts.append({"action": "bounded_cleanup", "outcome": "timed_out", "child_exit": process.poll(), "group_empty": group_empty(process.pid), "group_quiescent": group_quiescent(process.pid)})
    return False


CAPTURE_LIMIT = 256 * 1024


def reserve_receipt():
    """Reserve the caller-selected receipt before the native command starts."""
    path = os.environ.get("KOGEN_BOUNDED_EXEC_RECEIPT")
    if not path:
        return None, None
    try:
        return path, os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        error = "receipt already exists"
        print("Kogen compatibility receipt reservation failed: " + error, file=sys.stderr)
        return path, error
    except OSError as error:
        print("Kogen compatibility receipt reservation failed: " + str(error), file=sys.stderr)
        return path, str(error)


def write_receipt(receipt_fd, payload):
    if receipt_fd is None:
        return None
    try:
        encoded = json.dumps(payload, sort_keys=True).encode("utf-8")
        os.lseek(receipt_fd, 0, os.SEEK_SET)
        os.ftruncate(receipt_fd, 0)
        view = memoryview(encoded)
        while view:
            written = os.write(receipt_fd, view)
            if written <= 0:
                raise OSError("receipt write made no progress")
            view = view[written:]
        os.fsync(receipt_fd)
        current = os.lstat(os.environ["KOGEN_BOUNDED_EXEC_RECEIPT"])
        owned = os.fstat(receipt_fd)
        if (current.st_dev, current.st_ino) != (owned.st_dev, owned.st_ino):
            raise OSError("receipt pathname replaced during native execution")
        return None
    except OSError as error:
        print("Kogen compatibility receipt write failed: " + str(error), file=sys.stderr)
        return str(error)
    finally:
        os.close(receipt_fd)


def pump(stream, target, captured):
    """Forward a native protocol stream while retaining bounded compatibility evidence."""
    try:
        while True:
            chunk = stream.read1(8192)
            if not chunk:
                captured.complete = True
                return
            target.write(chunk)
            target.flush()
            remaining = CAPTURE_LIMIT - len(captured)
            if remaining > 0:
                captured.extend(chunk[:remaining])
            if len(chunk) > remaining:
                captured.truncated = True
    finally:
        stream.close()


class Capture(bytearray):
    truncated = False
    complete = False


def native_session_id(stdout):
    for line in stdout.decode("utf-8", "replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "thread.started" and isinstance(event.get("thread_id"), str):
            return event["thread_id"]
    return None


def main():
    if len(sys.argv) < 2:
        print("bounded_exec.py requires a command", file=sys.stderr)
        return 2
    attempts, process, status = [], None, None
    timed_out = cleanup_ok = cancelled = False
    cancellation_signal = None
    receipt_ok = True
    previous_handlers = {}
    receipt_path, receipt_fd = reserve_receipt()
    if isinstance(receipt_fd, str):
        return 1
    stdout, stderr = Capture(), Capture()
    pumps = []

    def cancelled_by(sig, _frame):
        nonlocal cancellation_signal
        cancellation_signal = sig
        raise InterruptedError("owned compatibility wrapper cancelled")

    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[sig] = signal.signal(sig, cancelled_by)
        child_env = os.environ.copy()
        child_env.pop("KOGEN_BOUNDED_EXEC_RECEIPT", None)
        child_env.pop("KOGEN_BOUNDED_EXEC_INVOCATION", None)
        process = subprocess.Popen(
            sys.argv[1:], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=child_env
        )
        pumps = [
            threading.Thread(target=pump, args=(process.stdout, sys.stdout.buffer, stdout), daemon=True),
            threading.Thread(target=pump, args=(process.stderr, sys.stderr.buffer, stderr), daemon=True),
        ]
        for worker in pumps:
            worker.start()
        try:
            status = process.wait(timeout=seconds("KOGEN_BOUNDED_EXEC_TIMEOUT", 240))
        except subprocess.TimeoutExpired:
            timed_out = True
            print("Kogen compatibility native turn timed out", file=sys.stderr)
        except InterruptedError:
            cancelled = True
    except InterruptedError:
        cancelled = True
    finally:
        for sig in previous_handlers:
            signal.signal(sig, signal.SIG_IGN)
        if process is not None:
            cleanup_ok = cleanup(process, time.monotonic() + seconds("KOGEN_BOUNDED_EXEC_CLEANUP_TIMEOUT", 8), attempts)
            if status is None:
                status = process.poll()
        for worker in pumps:
            worker.join(timeout=1)
        payload = {
            "invocation_id": os.environ.get("KOGEN_BOUNDED_EXEC_INVOCATION"),
            "native_exit": status,
            "native_session_id": native_session_id(stdout) if stdout.complete else None,
            "native_stderr": stderr.decode("utf-8", "replace"),
            "native_stderr_complete": stderr.complete and not stderr.truncated,
            "timed_out": timed_out,
            "cancelled": cancelled,
            "cancellation_signal": cancellation_signal,
            "cleanup": {"ok": cleanup_ok, "attempts": attempts},
        }
        receipt_error = write_receipt(receipt_fd, payload)
        receipt_ok = receipt_error is None
        if receipt_error:
            payload["receipt_error"] = receipt_error
        for sig, previous in previous_handlers.items():
            signal.signal(sig, previous)
    if timed_out:
        return 124
    if cancelled:
        return 128 + cancellation_signal
    if not cleanup_ok or not receipt_ok:
        return 1
    return status if status is not None and status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
