#!/usr/bin/env python3
"""Emit a Claude Code `-p --output-format stream-json` capture for offline fakes.

usage: claude_stream.py developer|reviewer SESSION MODEL < response
A developer response becomes the final assistant message and result text; a
reviewer response becomes the result's structured_output. FAKE_CLAUDE_HELPER
adds one kogen-scout helper linked to its parent Agent tool use, running on
that model; FAKE_CLAUDE_ROOT_MODEL overrides the root model to prove mismatch.
"""
import json
import os
import sys

kind, session, model = sys.argv[1:4]
body = sys.stdin.read().rstrip("\n")
root_model = os.environ.get("FAKE_CLAUDE_ROOT_MODEL", model)


def emit(event):
    print(json.dumps({**event, "session_id": session}))


emit({"type": "system", "subtype": "init", "model": model, "cwd": os.getcwd(),
      "mcp_servers": [], "apiKeySource": "none", "agents": ["kogen-scout", "kogen-worker", "kogen-expert"]})
helper = os.environ.get("FAKE_CLAUDE_HELPER")
if helper:
    emit({"type": "assistant", "parent_tool_use_id": None, "message": {"model": root_model, "content": [
        {"type": "tool_use", "id": "toolu_fake_scout", "name": "Agent",
         "input": {"subagent_type": "kogen-scout", "prompt": "inspect"}}]}})
    emit({"type": "assistant", "parent_tool_use_id": "toolu_fake_scout", "subagent_type": "kogen-scout",
          "message": {"model": helper, "content": [{"type": "text", "text": "I am claude-opus-5-5"}]}})
text = body if kind == "developer" else "Verdict submitted."
emit({"type": "assistant", "parent_tool_use_id": None,
      "message": {"model": root_model, "content": [{"type": "text", "text": text}]}})
result = {"type": "result", "subtype": "success", "is_error": False, "terminal_reason": "completed",
          "usage": {"input_tokens": 1, "output_tokens": 1}, "modelUsage": {model: {}}}
if kind == "developer":
    result["result"] = body
else:
    result["result"] = body
    if body:
        result["structured_output"] = json.loads(body)
emit(result)
