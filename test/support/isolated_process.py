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


def kill_group(pid, sig):
    try:
        os.killpg(pid, sig)
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
    timeout = float(sys.argv[1])
    result = Path(os.environ["KOGEN_ISOLATED_RESULT"])
    # Establish ownership before creating any child. The parent checks this
    # marker only after confirmed launcher exit, never while we are running.
    (result.parent / "supervisor-started").touch()
    try:
        process = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        shutil.rmtree(result.parent)
        raise
    deadline = time.monotonic() + timeout
    status = 124
    completed = False
    try:
        while process.poll() is None:
            if result.exists():
                status = int(result.read_text())
                completed = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            # Port closure (including an ExUnit timeout) cancels this owner too.
            readable, _, _ = select.select([sys.stdin], [], [], min(remaining, 0.02))
            if readable:
                os.read(sys.stdin.fileno(), 1)
                break
        else:
            status = process.returncode
    finally:
        # Also remove background work on normal/nonzero exit. Descendants remain
        # in this session even after the initial VM exits.
        cleanup_error = None
        try:
            reap_descendants(process.pid)
        except (OSError, RuntimeError) as error:
            cleanup_error = error
        if completed and cleanup_error is None:
            # Let BEAM shut down its own runtime helpers normally. Killing
            # erl_child_setup first makes BEAM crash and write a crash dump.
            result.with_suffix(".ack").touch()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                status = 125
            else:
                if process.returncode != status:
                    status = process.returncode
        kill_group(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass
        kill_group(process.pid, signal.SIGKILL)
        process.wait()
        wait_group(process.pid)
        if cleanup_error:
            raise cleanup_error
        if not result.parent.is_dir():
            raise RuntimeError("private fixture disappeared before child cleanup completed")
        print("isolated children terminated; private fixture still present", flush=True)
        try:
            shutil.rmtree(result.parent)
        except OSError as error:
            raise RuntimeError(f"could not remove private fixture {result.parent}: {error}") from error
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
