"""Per-launch receipt of an offline fake role, written from inside the process.

Every fake harness (`fake_claude*`, `fake_codex*`, `fake_hybrid`) calls this
with its stdin prompt on stdin and its argv as arguments. When the launch
carries `KOGEN_HARNESS_HOME` (every Build launch does), it appends one JSON
file under `<harness home>/launch-receipts/` recording the OS process state
the role actually sees: `pwd -P`, the Git toplevel, the environment, the task
context's locators and whether each control locator it was handed opens from
its own cwd. Outside a Build it records nothing. Tests assert these receipts,
never launch arguments.
"""

import json
import os
import re
import subprocess
import sys
import time

home = os.environ.get("KOGEN_HARNESS_HOME")
if not home:
    raise SystemExit(0)

prompt = sys.stdin.read()
cwd = os.path.realpath(os.getcwd())

try:
    toplevel = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
except OSError:
    toplevel = ""

context = {}
lines = prompt.splitlines()
markers = [i for i, line in enumerate(lines) if line == "KOGEN_TASK_CONTEXT"]
if markers and markers[-1] + 1 < len(lines):
    try:
        context = json.loads(lines[markers[-1] + 1])
    except ValueError:
        context = {}


def opens(path):
    return bool(path) and os.path.isfile(path)


locators = {}
if context.get("tracking_path"):
    locators["tracking_path"] = context["tracking_path"]
packet = (context.get("review_packet") or {}).get("path")
if packet:
    locators["review_packet"] = packet
for label, pattern in (("failure_receipt", r"Retained receipt: `([^`]+)`"), ("failure_log", r"Retained log: `([^`]+)`")):
    match = re.search(pattern, prompt)
    if match and not match.group(1).startswith("none"):
        locators[label] = match.group(1)

# One control-relative receipt log locator from the packet, resolved against
# the task context's control root.
if packet and opens(packet) and context.get("control_root"):
    try:
        with open(packet) as handle:
            text = handle.read()
        match = re.search(r'"log_path"\s*:\s*"([^"]+)"', text)
        if match:
            locators["packet_log_path"] = os.path.join(context["control_root"], match.group(1))
    except OSError:
        pass

receipt = {
    "role": os.environ.get("KOGEN_ROLE", ""),
    "argv": sys.argv[1:],
    "pid": os.getpid(),
    "pwd": cwd,
    "toplevel": os.path.realpath(toplevel) if toplevel else "",
    "env": dict(os.environ),
    "working_directory": context.get("working_directory"),
    "control_root": context.get("control_root"),
    "locators": locators,
    "opens": {label: opens(path) for label, path in locators.items()},
}

directory = os.path.join(home, "launch-receipts")
os.makedirs(directory, exist_ok=True)
name = "%d-%d-%s.json" % (time.time_ns(), os.getpid(), receipt["role"] or "readiness")
with open(os.path.join(directory, name), "w") as handle:
    json.dump(receipt, handle, sort_keys=True)
