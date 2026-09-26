#!/usr/bin/env python3
"""Process-custody wrapper, corrected: mirrors VerificationRunner's Python
supervisor. The wrapper (this process) stays OUTSIDE the child's process
group (it does not setsid itself) and launches the real work with
start_new_session=True, so the child (and everything it forks) is the
group leader of a NEW group == child.pid. The wrapper can then killpg(child.pid, ...)
without ever signalling itself. A parent-death watchdog (pipe EOF on fd 3, or
ppid==1 fallback) triggers the same kill path.

Usage: wrapper.py <out_dir> <argv...>
"""
import os, select, signal, subprocess, sys, time

out_dir = sys.argv[1]
argv = sys.argv[2:]

child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, start_new_session=True)
group = child.pid  # child is its own session/group leader; wrapper is not a member
with open(os.path.join(out_dir, "wrapper.pgid"), "w") as f:
    f.write(str(group))

watch_fd = 3
deadline = time.monotonic() + 280

def alive(g):
    try:
        os.killpg(g, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

def kill_group(reason):
    with open(os.path.join(out_dir, "wrapper.kill_group"), "a") as f:
        f.write(f"{reason} group={group}\n")
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            pass
        time.sleep(0.3)
        if not alive(group):
            return

while True:
    if child.poll() is not None:
        kill_group("child_exited")
        break
    readable = []
    try:
        readable, _, _ = select.select([watch_fd], [], [], 0.1)
    except OSError:
        if os.getppid() == 1:
            with open(os.path.join(out_dir, "wrapper.orphaned"), "w") as f:
                f.write("ppid=1 detected\n")
            kill_group("ppid_became_1")
            sys.exit(99)
        time.sleep(0.1)
        continue
    if readable:
        data = os.read(watch_fd, 4096)
        if data == b"":
            with open(os.path.join(out_dir, "wrapper.pipe_closed"), "w") as f:
                f.write("watchdog pipe EOF: launcher gone\n")
            kill_group("pipe_eof")
            sys.exit(98)
    if time.monotonic() > deadline:
        kill_group("deadline")
        break

sys.exit(child.returncode or 0)
