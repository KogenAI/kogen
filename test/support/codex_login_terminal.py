#!/usr/bin/python3
"""Synthetic native login runtime used only by the public-task offline test."""
import json
import os
import pathlib
import sys

args = sys.argv[1:]
home = pathlib.Path(os.environ["CODEX_HOME"])
trace = pathlib.Path(os.environ["KOGEN_TEST_NATIVE_TRACE"])
native = args[args.index("login") + 1:] if "login" in args else []
stdin = sys.stdin.read() if "--with-api-key" in native else ""
trace.parent.mkdir(parents=True, exist_ok=True)
with trace.open("a") as file:
    file.write(json.dumps({"args": args, "native": native, "scope": str(home), "stdin": stdin,
        "tty": sys.stdin.isatty()}) + "\n")

if native == ["status"]:
    sys.exit(0 if (home / "auth.json").is_file() else 1)
if "--help" in native:
    print("synthetic native login help")
    sys.exit(0)
if "--cancel" in native:
    sys.exit(130)
if "--with-api-key" in native:
    (home / "auth.json").write_text(stdin)
    sys.exit(0)
sys.exit(7)
