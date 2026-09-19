#!/usr/bin/env python3
"""Run Credo on exactly the supported source files currently changed from HEAD."""
import subprocess
import sys


def paths(command):
    output = subprocess.check_output(command)
    return [item.decode() for item in output.split(b"\0") if item]


changed = sorted(set(
    paths(["git", "diff", "--name-only", "-z", "HEAD", "--"]) +
    paths(["git", "ls-files", "--others", "--exclude-standard", "-z"])
))
supported = [path for path in changed if path.endswith((".ex", ".exs"))]

if not supported:
    sys.exit(0)

sys.exit(subprocess.call(["mix", "credo", "--strict", *supported]))
