#!/usr/bin/env python3
"""Interactive Claude Code replacement for hybrid-route Shape fixtures.

Behaves like `fake_claude_shaper` (answers `auth status`, then records argv
and the first message as the Shaper's prompt) but also records `KOGEN_EXPERT`
so hybrid-route tests can assert the cross-harness Expert assignment Kogen
carries into the Shaper's launch environment.
"""
import json
import os
import pathlib
import sys

args = sys.argv[1:]

if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai"}))
    sys.exit(0)

runtime = pathlib.Path(".kogen/runtime")
runtime.mkdir(parents=True, exist_ok=True)
(runtime / "shaping-args").write_text("\n".join(args) + "\n")

prompt = ""
if "--" in args:
    index = args.index("--")
    if index + 1 < len(args):
        prompt = args[index + 1]
(runtime / "shaping-prompt").write_text(prompt)

watched = [
    "CLAUDE_CONFIG_DIR",
    "KOGEN_ROLE",
    "DISABLE_AUTOUPDATER",
    "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT",
    "ANTHROPIC_API_KEY",
    "KOGEN_EXPERT",
]
defaults_unset = {"CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT", "ANTHROPIC_API_KEY"}
lines = []
for name in watched:
    value = os.environ.get(name)
    if value is None and name in defaults_unset:
        value = "unset"
    lines.append("{}={}".format(name, value if value is not None else ""))
(runtime / "shaping-env").write_text("\n".join(lines) + "\n")

sys.exit(int(os.environ.get("FAKE_CLAUDE_SHAPER_EXIT", "0")))
