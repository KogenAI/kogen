"""Offline native stand-in placed through the production manifest/promotion code."""
import importlib.util
import pathlib
import sys

root, installer_path = map(pathlib.Path, sys.argv[1:3])
spec = importlib.util.spec_from_file_location("installer", installer_path)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

program = r'''#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
home = pathlib.Path(os.environ["CODEX_HOME"])
trace = pathlib.Path(os.environ["KOGEN_TEST_NATIVE_TRACE"])
auth = home / "auth.json"
with trace.open("a") as f:
    f.write(json.dumps({"args": args, "scope": str(home), "home": os.environ.get("HOME"),
        "override": os.environ.get("OPENAI_API_KEY"), "executable": sys.argv[0]}) + "\n")
if "login" in args:
    native = args[args.index("login") + 1:]
    if native == ["status"]:
        print("SYNTHETIC-NATIVE-SECRET-DO-NOT-PRINT" if auth.exists() else "Not logged in", file=sys.stderr)
        sys.exit(0 if auth.is_file() else 1)
    if "--help" in native:
        print("native login help")
        sys.exit(0)
    if "--cancel" in native:
        sys.exit(130)
    if "--with-api-key" in native:
        auth.write_text(sys.stdin.read())
        sys.exit(0)
    sys.exit(7)
if "exec" in args:
    sys.stdin.read()
    identity = "managed-developer"
    if "--output-last-message" in args:
        identity = "managed-reviewer"
        message = {"candidate_id":"fixture-candidate", "attempt_token":"fixture-attempt",
                   "verdict":"accept", "scenarios":[], "dispositions":[], "findings":[]}
        pathlib.Path(args[args.index("--output-last-message") + 1]).write_text(json.dumps(message))
    print(json.dumps({"type": "thread.started", "thread_id": identity}))
    print(json.dumps({"type": "turn.completed"}))
    sys.exit(0)
sys.exit(0)
'''

platform = installer.platform_name()
installer._owned_directory(root / "runtimes")
for version in ["0.154.0", "0.200.0"]:
    target = installer._runtime(root, version, platform)
    executable, resources = installer._required_paths(platform)
    for relative in [executable, *resources]:
        path = target / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(program if relative == executable else (
            '{"layoutVersion":1,"entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}\n'
            if relative.endswith("codex-package.json") else "#!/bin/sh\nexit 0\n"))
        path.chmod(0o755)
    installer._write_manifest(target, version, platform)
installer.activate(root, "0.154.0", "-", platform=platform)
