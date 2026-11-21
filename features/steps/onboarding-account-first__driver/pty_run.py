import json
import os
import pty
import re
import select
import signal
import sys
import time

binary, cwd, home = sys.argv[1], sys.argv[2], sys.argv[3]
steps = json.loads(sys.argv[4])
args = json.loads(sys.argv[5])

pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    env = dict(os.environ)
    env["HOME"] = home
    env["KOGEN_NO_BROWSER"] = "1"
    os.execve(binary, [binary] + args, env)

buf = ""
eof = False


def pump(timeout):
    global buf, eof
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return
    try:
        data = os.read(fd, 4096)
    except OSError:
        eof = True
        return
    if not data:
        eof = True
        return
    buf += data.decode("utf-8", "replace")


pos = 0
failed = None
for expect, send in steps:
    start = pos
    deadline = time.time() + 30
    match = None
    while time.time() < deadline:
        match = re.compile(expect, re.M).search(buf, pos)
        if match or eof:
            break
        pump(0.2)
    if not match:
        failed = "prompt not seen: " + expect
        break
    pos = match.end()
    if send is None:
        continue
    if send.startswith("@choice:"):
        label = send[len("@choice:"):]
        # The number shown beside the label when the prompt numbers its choices; else the label itself.
        found = re.search(r"^\s*(\d+)[).:]?\s+" + re.escape(label), buf[start:pos], re.M | re.I)
        send = found.group(1) if found else label
    time.sleep(0.4)
    os.write(fd, (send + "\r").encode())

deadline = time.time() + 20
while not eof and time.time() < deadline and failed is None:
    pump(0.3)
code = None
try:
    done, status = os.waitpid(pid, os.WNOHANG)
    if done == 0 and eof:
        time.sleep(0.3)
        done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
    else:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
except ChildProcessError:
    pass
print(json.dumps({"output": buf, "exit": code, "failed": failed}))
