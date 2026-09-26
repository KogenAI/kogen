import os, signal, sys
# Make this process its own group and the terminal's foreground group, then exec.
os.setpgid(0, 0)
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
try: os.tcsetpgrp(0, os.getpgrp())
except OSError as e: print("tcsetpgrp failed", e, file=sys.stderr)
signal.signal(signal.SIGTTOU, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
