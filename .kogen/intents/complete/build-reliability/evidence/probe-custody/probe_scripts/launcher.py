#!/usr/bin/env python3
import os, subprocess, sys, time

out_dir = sys.argv[1]
wrapper = sys.argv[2]
provider = sys.argv[3]
use_pipe = sys.argv[4] == "pipe"

with open(os.path.join(out_dir, "launcher.pid"), "w") as f:
    f.write(str(os.getpid()))

if use_pipe:
    r, w = os.pipe()
    os.dup2(r, 3)
    os.set_inheritable(3, True)
    os.close(r)
    proc = subprocess.Popen([wrapper, out_dir, provider], pass_fds=(3,))
    # Deliberately keep fd 3 (dup of w... no: fd3 is now r's dup) open? We must
    # keep the ORIGINAL write end w open in the launcher so the pipe stays live
    # until the launcher dies; fd 3 in the launcher is the read end (unused
    # here) which we can close without affecting w.
    pass  # fd 3 read-end alias may already be closed by subprocess internals
else:
    proc = subprocess.Popen([wrapper, out_dir, provider])

with open(os.path.join(out_dir, "launcher.started"), "w") as f:
    f.write("ready\n")

time.sleep(300)
