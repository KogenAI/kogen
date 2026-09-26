"""Runs `test/support/custody_controller_standin.exs` under a real pty (like
a Shaper's real terminal) with `ELIXIR_ERL_OPTIONS=+Bd`, waits for it to
print READY, sends Ctrl-C (0x03), and reports whether and when the process
exited. Adapted from evidence/probe-custody/pty_signal.py.

Usage: pty_ctrlc.py <mix> <standin.exs> <mode> <control> <out> <fake_provider>
Prints one line: "exited=<seconds|None> status=<waitpid status|None>"
"""
import os
import pty
import select
import sys
import time

mix, standin, mode, control, out, fake_provider = sys.argv[1:7]

env = dict(os.environ)
env["ELIXIR_ERL_OPTIONS"] = "+Bd"
env["FAKE_PROVIDER"] = fake_provider

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(mix, [mix, "run", standin, mode, control, out], env)

out_bytes = b""
deadline = time.time() + 25
sent_at = None
status = None

while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out_bytes += chunk
    if sent_at is None and b"READY" in out_bytes:
        sent_at = time.time()
        os.write(fd, b"\x03")
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
else:
    os.kill(pid, 9)
    os.waitpid(pid, 0)

exited = (time.time() - sent_at) if sent_at else None
print(f"exited={exited} status={status}")
