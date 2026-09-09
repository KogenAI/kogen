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

sys.dont_write_bytecode = True
from isolated_process import reap_descendants


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("pipe", "pty"), required=True)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required")
    return args


def wait_for_exit(process, timeout):
    deadline = time.monotonic() + timeout
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)

    if process.poll() is None:
        reap_descendants(process.pid)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise RuntimeError("command waited for stdin instead of completing")

    if process.returncode:
        raise RuntimeError(f"command exited with status {process.returncode}")


def main():
    args = parse_args()
    environment = os.environ.copy()

    if args.mode == "pipe":
        process = subprocess.Popen(
            args.command, stdin=subprocess.PIPE, env=environment, start_new_session=True
        )
        try:
            wait_for_exit(process, args.timeout)
        finally:
            process.stdin.close()
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
        try:
            wait_for_exit(process, args.timeout)
        finally:
            os.close(master)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"terminal probe failed: {error}", file=sys.stderr)
        sys.exit(1)
