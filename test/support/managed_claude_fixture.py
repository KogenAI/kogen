"""Offline Claude Code stand-in placed through the production manifest/promotion code.

usage: managed_claude_fixture.py ROOT INSTALLER
The stand-in records every invocation (argv and the environment Kogen controls)
to KOGEN_TEST_NATIVE_TRACE, answers `auth status` from a marker in its
CLAUDE_CONFIG_DIR, completes or cancels an interactive login, and replays a
minimal stream-json turn for `-p` role launches. It never contacts a provider.
"""
import importlib.util
import json
import pathlib
import sys

root, installer_path = map(pathlib.Path, sys.argv[1:3])
spec = importlib.util.spec_from_file_location("installer", installer_path)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

program = r'''#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
scope = pathlib.Path(os.environ["CLAUDE_CONFIG_DIR"])
watched = ["HOME", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
           "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
           "CLAUDECODE", "DISABLE_AUTOUPDATER", "KOGEN_ROLE"]
with pathlib.Path(os.environ["KOGEN_TEST_NATIVE_TRACE"]).open("a") as trace:
    trace.write(json.dumps({"args": args, "scope": str(scope), "executable": sys.argv[0],
                            "env": {name: os.environ.get(name) for name in watched}}) + "\n")
login = scope / ".fake-login"
if args[:2] == ["auth", "status"]:
    if login.is_file():
        print(json.dumps({"loggedIn": True, "authMethod": login.read_text().strip(),
                          "email": "SYNTHETIC-SECRET@example.invalid", "orgName": "SYNTHETIC-ORG"}))
        sys.exit(0)
    print(json.dumps({"loggedIn": False, "authMethod": "none"}))
    sys.exit(1)
if "-p" not in args:
    if "--cancel" in args:
        sys.exit(130)
    login.write_text("console\n" if "--console" in args else "claude.ai\n")
    sys.exit(0)
sys.stdin.read()
session = args[args.index("--session-id") + 1] if "--session-id" in args else args[args.index("--resume") + 1]
model = args[args.index("--model") + 1]
def emit(event):
    print(json.dumps({**event, "session_id": session}))
emit({"type": "system", "subtype": "init", "model": model})
emit({"type": "assistant", "parent_tool_use_id": None, "message": {"model": model, "content": []}})
result = {"type": "result", "subtype": "success", "is_error": False, "result": "managed turn"}
if "--json-schema" in args:
    result["structured_output"] = {"candidate_id": "fixture-candidate", "attempt_token": "fixture-attempt",
                                   "verdict": "accept", "scenarios": [], "dispositions": [], "findings": []}
emit(result)
'''

platform = installer.platform_name()
version = installer.INITIAL_VERSION
installer._owned_directory(root, root=True)
installer._owned_directory(root / "runtimes")
target = installer._runtime(root, version, platform)
target.mkdir(parents=True)
(target / "claude").write_text(program)
(target / "claude").chmod(0o755)
(target / "package.json").write_text(json.dumps({
    "name": "@anthropic-ai/claude-code-" + platform, "version": version,
    "os": ["darwin"], "cpu": ["arm64" if platform == "darwin-arm64" else "x64"]}))
installer._write_manifest(target, version, platform)
installer.activate(root, version, "-", platform=platform)
