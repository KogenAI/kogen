#!/usr/bin/env python3
"""Runs a command with an open pipe or PTY stdin and a bounded completion wait.

The probe deliberately retains the writer side of stdin. It catches test fakes
that accidentally wait for EOF even though an interactive Shaper has no EOF.
"""

import argparse
import os
import pty
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
from isolated_process import descendants, reap_descendants, wait_group


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("pipe", "pty"), required=True)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--startup-timeout", type=float, default=2.0)
    parser.add_argument("--ready-marker", help="opt into child readiness via a fresh marker")
    parser.add_argument("--owned-pid-file", help="child-written PID file for owned background work")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required")
    return args


def terminate(process, owned):
    """Terminate the owned process group and all descendants."""
    cleanup_error = None
    try:
        reap_descendants(process.pid)
    except (OSError, RuntimeError) as error:
        cleanup_error = error
    for pid in owned:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    wait_group(process.pid)
    for pid in owned:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.005)
        else:
            raise RuntimeError(f"terminal descendant {pid} survived cleanup")
    if cleanup_error is not None:
        raise cleanup_error


def remember_descendants(process, owned):
    try:
        owned.update(descendants(process.pid))
    except (OSError, subprocess.SubprocessError):
        pass


def remember_pid_file(path, owned):
    if path and Path(path).is_file():
        owned.add(int(Path(path).read_text().strip()))


def wait_for_exit(process, timeout, startup_timeout, marker, owned):
    startup_deadline = time.monotonic() + startup_timeout
    if marker is not None:
        while not marker.exists():
            remember_descendants(process, owned)
            if marker.exists():
                break
            if process.poll() is not None:
                raise RuntimeError(
                    f"command exited before readiness (status {process.returncode})"
                )
            if time.monotonic() >= startup_deadline:
                raise RuntimeError("command did not become ready before startup deadline")
            time.sleep(0.01)

    deadline = time.monotonic() + timeout
    while process.poll() is None and time.monotonic() < deadline:
        remember_descendants(process, owned)
        time.sleep(0.01)

    if process.poll() is None:
        if marker is None:
            raise RuntimeError("command waited for stdin instead of completing")
        raise RuntimeError("command did not complete after readiness deadline")

    if process.returncode:
        raise RuntimeError(f"command exited with status {process.returncode}")


def main():
    args = parse_args()
    environment = os.environ.copy()
    owned = set()
    marker_path = None
    if args.ready_marker:
        marker_path = Path(args.ready_marker)
        if marker_path.exists():
            raise RuntimeError(f"readiness marker already exists: {marker_path}")
        marker_path.parent.mkdir(parents=True, exist_ok=True)
        environment["KOGEN_READY_MARKER"] = str(marker_path)

    if args.mode == "pipe":
        process = subprocess.Popen(
            args.command, stdin=subprocess.PIPE, env=environment, start_new_session=True
        )
        failure = None
        try:
            wait_for_exit(process, args.timeout, args.startup_timeout, marker_path, owned)
        except BaseException as error:
            failure = error
        finally:
            remember_pid_file(args.owned_pid_file, owned)
            try:
                terminate(process, owned)
            except BaseException as error:
                if failure is None:
                    failure = error
            finally:
                process.stdin.close()
        if failure is not None:
            raise failure
    else:
        master, slave = pty.openpty()
        process = subprocess.Popen(
            args.command,
            stdin=slave,
            env=environment,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave)
        failure = None
        try:
            wait_for_exit(process, args.timeout, args.startup_timeout, marker_path, owned)
        except BaseException as error:
            failure = error
        finally:
            remember_pid_file(args.owned_pid_file, owned)
            try:
                terminate(process, owned)
            except BaseException as error:
                if failure is None:
                    failure = error
            finally:
                os.close(master)
        if failure is not None:
            raise failure


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"terminal probe failed: {error}", file=sys.stderr)
        sys.exit(1)
