#!/usr/bin/env python3
"""Hostile-host discovery fixture and native prompt-discovery probe.

This is intentionally a narrow compatibility helper.  It never supplies a
registry, credentials, or model prompt; `probe` only invokes Codex's diagnostic
commands with the environment supplied by the isolated launcher.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any


class DiscoveryError(RuntimeError):
    pass


def _json(value: str) -> Any:
    try:
        return json.loads(value)
    except ValueError as error:
        raise DiscoveryError("expected JSON argument") from error


def _write(path: Path, content: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if mode is not None:
        path.chmod(mode)


def _skill(name: str, marker: str) -> str:
    return "---\nname: " + name + "\ndescription: Synthetic discovery fixture\n---\n\n" + marker + "\n"


def _git_ancestor(path: Path) -> Path | None:
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists() or (candidate / ".git").is_symlink():
            return candidate
    return None


def seed(fixture: Path | str, config: dict[str, Any]) -> dict[str, Any]:
    fixture = Path(fixture).resolve()
    if not fixture.is_dir():
        raise DiscoveryError("fixture must be an existing directory")
    if (fixture / "AGENTS.md").exists():
        raise DiscoveryError("fixture must not contain AGENTS.md")
    personal = str(config.get("personal_sentinel", "personal-discovery-sentinel"))
    # The sentinel is the actual project Skill name, because native prompt-input
    # reports discovered Skill catalog names rather than arbitrary file bytes.
    project = str(config.get("project_sentinel", "project-discovery-sentinel"))
    if not personal or not project or personal == project:
        raise DiscoveryError("discovery sentinels must be distinct nonempty strings")
    # A compatibility fixture is normally its own Git root, so its sibling is
    # suitable.  If a caller supplies a fixture nested in a repository, step
    # outside that repository before making the hostile HOME.
    git_root = _git_ancestor(fixture)
    home_parent = git_root.parent if git_root is not None and git_root != fixture else fixture.parent
    home = home_parent / (fixture.name + "-hostile-home")
    if home.exists() or home.is_symlink():
        raise DiscoveryError("hostile fixture home already exists: " + str(home))
    marker = home / "hostile-mcp-started"
    home.mkdir(mode=0o700)
    _write(home / ".agents/skills/personal-context/SKILL.md", _skill(personal, personal))
    _write(home / ".codex/skills/personal-context/SKILL.md", _skill(personal + "-codex", personal))
    _write(home / ".codex/AGENTS.md", "Synthetic personal instruction: " + personal + "\n")
    _write(home / ".codex/rules/hostile.rules", 'prefix_rule(pattern=["echo", "PERSONAL_RULE"], decision="prompt")\n')
    selected_model = config.get("shaping", {}).get("model", "gpt-5.6-sol")
    _write(home / ".codex/config.toml", 'model = ' + json.dumps(selected_model) + '\nmodel_reasoning_effort = "high"\n')
    _write(home / ".codex/personal-hostile.config.toml", 'developer_instructions = ' + json.dumps(personal + " profile instructions") + '\n')
    _write(home / ".codex/plugins/cache/personal-fixture/.codex-plugin/plugin.json",
           json.dumps({"name": "personal-fixture", "version": "1.0.0", "description": personal}) + "\n")
    _write(home / ".codex/sessions/synthetic-personal-session", "Synthetic unrelated native session marker\n")
    server = "#!/usr/bin/env python3\nimport pathlib, sys\npathlib.Path(sys.argv[1]).touch()\nfor line in sys.stdin:\n print('{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"serverInfo\":{\"name\":\"hostile\",\"version\":\"1\"}}}', flush=True)\n"
    command = home / "bin/hostile-mcp"
    _write(command, server, 0o700)
    _write(home / ".codex/config.toml", (home / ".codex/config.toml").read_text() +
           "\n[features]\napps = true\nplugins = true\n[apps.personal_fixture]\nenabled = true\n" +
           "\n[mcp_servers.hostile]\ncommand = " + json.dumps(str(command)) + "\nargs = [" + json.dumps(str(marker)) + "]\n")
    hook = home / "bin/hostile-startup"
    _write(hook, "#!/bin/sh\nprintf started > " + shlex.quote(str(home / "hostile-hook-started")) + "\n", 0o700)
    _write(home / ".codex/hooks.json", json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": shlex.quote(str(hook))}]}]}}) + "\n")
    _write(fixture / ".agents/skills/project-context/SKILL.md", _skill(project, project))
    if not (fixture / "README.md").exists():
        _write(fixture / "README.md", "# Compatibility discovery fixture\n\nProject discovery context lives here.\n")
    context = {"home": str(home), "xdg": None, "marker": str(marker),
               "hook_marker": str(home / "hostile-hook-started"),
               "personal_sentinel": personal, "project_sentinel": project}
    _write(fixture / ".kogen-discovery-context.json", json.dumps(context, sort_keys=True) + "\n")
    return context


def _run(command: list[str], fixture: Path, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=fixture, env=environment, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30, check=False)


def _contains(result: subprocess.CompletedProcess[str], text: str) -> bool:
    return text in result.stdout or text in result.stderr


def _explicit_missing_mcp(result: subprocess.CompletedProcess[str]) -> bool:
    if result.returncode == 0:
        return False
    body = result.stdout.strip()
    try:
        decoded = json.loads(body)
        message = decoded.get("error", "") if isinstance(decoded, dict) else ""
    except ValueError:
        message = result.stdout + "\n" + result.stderr
    return re.search(r"no mcp server named [\"' ]?hostile[\"']?(?: found)?(?:[.\s]|$)", str(message), re.IGNORECASE) is not None


def probe(executable: str, fixture: Path | str, spec: dict[str, Any], runtime_args: list[str]) -> dict[str, Any]:
    fixture = Path(fixture).resolve()
    try:
        context = json.loads((fixture / ".kogen-discovery-context.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise DiscoveryError("missing discovery seed context") from error
    if not isinstance(runtime_args, list) or not all(isinstance(arg, str) for arg in runtime_args):
        raise DiscoveryError("runtime arguments must be a JSON string list")
    root_args = spec.get("root_args", [])
    if not isinstance(root_args, list) or not all(isinstance(arg, str) for arg in root_args):
        raise DiscoveryError("root_args must be a JSON string list")
    for key in ("home", "marker", "project_sentinel"):
        if key in spec and spec[key] != context[key]:
            raise DiscoveryError("discovery probe spec does not match its seed context")
    marker, personal, project = (Path(context["marker"]), context["personal_sentinel"], context["project_sentinel"])
    hook_marker = Path(context["hook_marker"])
    marker.unlink(missing_ok=True)
    hook_marker.unlink(missing_ok=True)
    safe_env = dict(os.environ)  # supplied by Environment.prepare; do not reconstruct it here
    safe_debug = _run([executable, *runtime_args, "debug", "prompt-input"], fixture, safe_env)
    safe_mcp = _run([executable, *runtime_args, "mcp", "get", "hostile", "--json"], fixture, safe_env)
    safe_project_visible = safe_debug.returncode == 0 and _contains(safe_debug, project)
    safe_personal_absent = not _contains(safe_debug, personal)
    safe_mcp_absent = _explicit_missing_mcp(safe_mcp)
    safe_marker_absent = not marker.exists()
    safe_hook_marker_absent = not hook_marker.exists()

    hostile_env = dict(os.environ)
    hostile_env["HOME"] = context["home"]
    hostile_env["CODEX_HOME"] = str(Path(context["home"]) / ".codex")
    try:
        hostile_debug = _run([executable, *root_args, "--profile", "personal-hostile", "debug", "prompt-input"], fixture, hostile_env)
        hostile_marker_started = marker.exists()
        hostile_hook_marker_started = hook_marker.exists()
        hostile_mcp = _run([executable, *root_args, "--profile", "personal-hostile", "mcp", "get", "hostile", "--json"], fixture, hostile_env)
    finally:
        # A native negative diagnostic may start the hostile test server.  Return
        # the fixture to its seeded marker state before later compatibility work.
        marker.unlink(missing_ok=True)
        hook_marker.unlink(missing_ok=True)
    hostile_personal_visible = hostile_debug.returncode == 0 and _contains(hostile_debug, personal)
    hostile_mcp_present = hostile_mcp.returncode == 0 and _contains(hostile_mcp, "hostile")
    receipt = {"safe_project_visible": safe_project_visible, "safe_personal_absent": safe_personal_absent,
               "safe_mcp_absent": safe_mcp_absent, "safe_marker_absent": safe_marker_absent,
               "safe_hook_marker_absent": safe_hook_marker_absent,
               "hostile_personal_visible": hostile_personal_visible, "hostile_mcp_present": hostile_mcp_present,
               "hostile_marker_started": hostile_marker_started,
               "hostile_hook_marker_started": hostile_hook_marker_started,
               "fixture": str(fixture), "home": context["home"], "project_sentinel": project}
    if not all(receipt[key] for key in ("safe_project_visible", "safe_personal_absent", "safe_mcp_absent",
                                        "safe_marker_absent", "safe_hook_marker_absent", "hostile_personal_visible", "hostile_mcp_present")):
        raise DiscoveryError(json.dumps(receipt, sort_keys=True))
    return receipt


def _main(arguments: list[str]) -> int:
    if len(arguments) < 2:
        raise DiscoveryError("usage: discovery.py seed FIXTURE CONFIG_JSON | probe EXECUTABLE FIXTURE SPEC_JSON ARGS_JSON")
    command = arguments[0]
    if command == "seed" and len(arguments) == 3:
        result = seed(arguments[1], _json(arguments[2]))
    elif command == "probe" and len(arguments) == 5:
        result = probe(arguments[1], arguments[2], _json(arguments[3]), _json(arguments[4]))
    else:
        raise DiscoveryError("invalid discovery command arguments")
    print(json.dumps({"ok": True, **result}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(_main(sys.argv[1:]))
    except DiscoveryError as error:
        print(json.dumps({"ok": False, "error": str(error)}, separators=(",", ":")))
        raise SystemExit(1)
