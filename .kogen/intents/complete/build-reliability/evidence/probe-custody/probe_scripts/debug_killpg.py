import os, signal, subprocess, sys, time

out_dir = sys.argv[1]
provider = sys.argv[2]
os.setsid()
group = os.getpid()
print("wrapper pid/pgid", group, flush=True)
child = subprocess.Popen([provider], stdin=subprocess.DEVNULL)
while child.poll() is None:
    time.sleep(0.1)
print("child exited", child.returncode, flush=True)
gpid = int(open(os.path.join(out_dir, "grandchild.pid")).read())
print("attempting killpg", group, "grandchild alive before:", os.path.exists(f"/proc/{gpid}") if False else "n/a", flush=True)
try:
    os.killpg(group, signal.SIGTERM)
    print("SIGTERM sent ok", flush=True)
except Exception as e:
    print("SIGTERM error", repr(e), flush=True)
time.sleep(0.3)
try:
    os.killpg(group, signal.SIGKILL)
    print("SIGKILL sent ok", flush=True)
except Exception as e:
    print("SIGKILL error", repr(e), flush=True)
time.sleep(0.3)
try:
    os.kill(gpid, 0)
    print("grandchild STILL ALIVE", flush=True)
except ProcessLookupError:
    print("grandchild dead", flush=True)
