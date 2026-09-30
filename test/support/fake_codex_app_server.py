#!/usr/bin/env python3
"""Offline stand-in for `codex [flags] app-server --stdio` (JSON-RPC lines).

Answers initialize, app/list, app/installed, plugin/installed and
account/read as the pinned runtime does, from the apps/plugins flags it was
launched with and FAKE_ACCOUNT_MODE:

  normal     enabled: remote plugins installed+enabled, apps callable;
             disabled: empty discovery, apps not callable, no plugins
  leak       disabled still reports a callable app and an enabled plugin
  timeout    disabled never answers app/list
  no-remote  enabled reports no remote plugin (no positive control)
  home       reports a codexHome other than CODEX_HOME
  crash      exits before answering

Records its pid in FAKE_APP_SERVER_PIDS (one per line) so a test can check
the observer reaped it.
"""

import json
import os
import sys
import time

args = sys.argv[1:]
mode = os.environ.get("FAKE_ACCOUNT_MODE", "normal")


def flag(name):
    for i, arg in enumerate(args[:-1]):
        if arg in ("--enable", "--disable") and args[i + 1] == name:
            return arg == "--enable"
    return True


enabled = flag("apps") and flag("plugins")
pids = os.environ.get("FAKE_APP_SERVER_PIDS")
if pids:
    with open(pids, "a") as handle:
        handle.write(f"{os.getpid()}\n")

if mode == "crash":
    sys.exit(3)

home = os.environ.get("CODEX_HOME", "")
if enabled and home:
    # Like real Codex with plugins enabled: it creates a plugin cache in its home.
    cache = os.path.join(home, "plugins/cache/m/p")
    os.makedirs(cache, exist_ok=True)
    with open(os.path.join(cache, "plugin.json"), "w") as handle:
        handle.write("{}")
if mode == "home":
    home = home + "-other"

apps = [
    {"id": "asdk_app_1", "runtimeName": "Todoist", "enabled": enabled, "callable": enabled},
    {"id": "asdk_app_2", "runtimeName": "Stripe", "enabled": enabled, "callable": enabled},
]
remote = [
    {
        "id": "github@openai-curated-remote",
        "source": {"type": "remote"},
        "installed": True,
        "enabled": True,
    },
    {
        "id": "figma@openai-curated-remote",
        "source": {"type": "remote"},
        "installed": True,
        "enabled": True,
    },
]
if not enabled and mode == "leak":
    apps[0].update({"enabled": True, "callable": True})
    marketplaces = [{"name": "openai-curated-remote", "plugins": remote[:1]}]
elif enabled and mode != "no-remote":
    marketplaces = [{"name": "openai-curated-remote", "plugins": remote}]
else:
    marketplaces = []


def answer(request):
    method = request.get("method")
    if method == "initialize":
        return {"codexHome": home, "userAgent": "fake/0.158.0", "platformOs": "macos"}
    if method == "app/list":
        if not enabled and mode == "timeout":
            return None
        if enabled:
            return "timeout-like"  # the enabled catalog fetch is not needed
        return {"data": [], "nextCursor": None}
    if method == "app/installed":
        return {"apps": apps}
    if method == "plugin/installed":
        return {"marketplaces": marketplaces, "marketplaceLoadErrors": []}
    if method == "account/read":
        return {"account": {"id": "acct-1", "type": "chatgpt", "email": "x@example.invalid"}}
    return None


for line in sys.stdin:
    try:
        request = json.loads(line)
    except ValueError:
        continue
    if "id" not in request:
        continue
    result = answer(request)
    if result is None or result == "timeout-like":
        continue
    sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
    sys.stdout.flush()

time.sleep(0)
