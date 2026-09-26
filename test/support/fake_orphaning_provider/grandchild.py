import os
import signal
import sys
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
out_dir = sys.argv[1]
with open(os.path.join(out_dir, "grandchild.pid"), "w") as handle:
    handle.write(str(os.getpid()))
time.sleep(300)
