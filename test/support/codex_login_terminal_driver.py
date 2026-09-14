#!/usr/bin/env python3
"""Run a command under a controlling pseudo-terminal and send one login value."""
import json
import os
import pty
import select
import signal
import sys
import time

cwd, value, *command = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp(command[0], command)
os.write(master, value.encode() + b"\n\x04")
deadline = time.monotonic() + 20
status = None
chunks = []
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                chunks.append(os.read(master, 65536))
            except OSError:
                pass
        waited, raw = os.waitpid(pid, os.WNOHANG)
        if waited:
            status = os.waitstatus_to_exitcode(raw)
            break
finally:
    if status is None:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        status = 124
    os.close(master)
print(json.dumps({"status": status, "output": b"".join(chunks).decode("utf-8", "replace")}))
