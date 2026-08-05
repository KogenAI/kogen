#!/usr/bin/env python3
"""enforcement_compiler.py — generate bash denial hooks from registry.yaml.

Usage:
    python3 enforcement_compiler.py \\
        --registry shared/enforcement/registry.yaml \\
        --bash-out harnesses/claude/hooks

For each entry with generated: true the compiler emits a bash hook to
<bash-out>/<id>.sh.

Pattern dialect translation:
  Registry uses regex-neutral syntax (\\s, \\b, etc.)
  Bash (ERE):  \\s → [[:space:]]

Forbidden pattern constructs (rejected by compiler):
  backreferences: \\1, \\2, ...
  lookahead:      (?=...), (?!...)
  lookbehind:     (?<=...), (?<!...)
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Forbidden pattern guard
# ---------------------------------------------------------------------------

_FORBIDDEN_RE = re.compile(
    r"\\[1-9]"          # backreferences
    r"|"
    r"\(\?[=!<]"        # lookahead / lookbehind
)


def _check_forbidden(pattern, entry_id):
    """Raise ValueError if pattern contains forbidden constructs."""
    m = _FORBIDDEN_RE.search(pattern)
    if m:
        raise ValueError(
            f"Entry '{entry_id}': pattern contains forbidden construct "
            f"'{m.group()}' at position {m.start()}: {pattern!r}"
        )


# ---------------------------------------------------------------------------
# Harnesses token guard
# ---------------------------------------------------------------------------

_VALID_HARNESSES = ("all", "claude")


def _validate_harnesses(eid, harnesses_val):
    """Fail-loud if an entry's harnesses token is outside the live contract.

    Mirrors the match/match_all exclusivity guard form: sys.exit with
    "ERROR: entry '<id>': ...". A typo (claude_code, both) would otherwise
    make emit_bash false -> the rule silently vanishes. This makes that a
    loud compile abort.
    """
    if harnesses_val not in _VALID_HARNESSES:
        sys.exit(
            f"ERROR: entry '{eid}': harnesses '{harnesses_val}' "
            f"not in (all, claude)"
        )


# ---------------------------------------------------------------------------
# Dialect translation
# ---------------------------------------------------------------------------

def _to_bash(pattern):
    r"""Translate registry regex-neutral pattern to bash ERE.

    \\s → [[:space:]]  (only the two-char sequence \\s, not inside char classes)
    All other tokens pass through.
    """
    # Replace \s with [[:space:]] — but only when not inside [...] already.
    # Simple approach: replace all \s occurrences (the YAML already escaped
    # the backslash so in Python the string contains a literal backslash-s).
    return pattern.replace(r"\s", "[[:space:]]")

# ---------------------------------------------------------------------------
# Registry loading
# ---------------------------------------------------------------------------

def load_registry(registry_path):
    """Load registry YAML via yq → JSON → Python list."""
    try:
        result = subprocess.run(
            ["yq", "-o=json", ".", str(registry_path)],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        sys.exit("ERROR: yq not found on PATH. Install with: brew install yq")
    except subprocess.CalledProcessError as e:
        sys.exit(f"ERROR: yq failed: {e.stderr}")

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: JSON parse failed: {e}")

    if not isinstance(data, list):
        sys.exit("ERROR: registry.yaml must be a YAML list")

    return data


# ---------------------------------------------------------------------------
# Bash hook generation
# ---------------------------------------------------------------------------

_BASH_TEMPLATE_SINGLE = """\
#!/bin/bash
# {id}.sh — PreToolUse hook: {description}.
#
# HOOK-MANIFEST:
# event: {event}
# matcher: {tool_guard}
# surface: {surface}
# signal: {signal}
# role: {role}
# harnesses: {harnesses}
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
{role_source_prelude}parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard {tool_guard} tool.
if [ "$TOOL_NAME" != "{tool_guard}" ]; then
    exit 0
fi
{bypass_roles_prelude}{agent_type_guard}
# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Deny: pattern match.
if printf '%s' "{match_subject}" | grep -qE '{match_bash}'; then
    deny "{message}"
    exit 0
fi

exit 0
"""

# Template for FILE_PATH source, deny mode (deny when pattern DOES match).
# Multi-tool guard uses a case statement.
_BASH_TEMPLATE_FILEPATH_DENY = """\
#!/bin/bash
# {id}.sh — PreToolUse hook: {description}.
#
# HOOK-MANIFEST:
# event: {event}
# matcher: {tool_guard}
# surface: {surface}
# signal: {signal}
# role: {role}
# harnesses: {harnesses}
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only guard {tool_guard} tool(s).
case "$TOOL_NAME" in
{tool_guard_case_arms}
*) exit 0 ;;
esac
{agent_type_guard}
# Deny: normalise to repo-relative path, then check pattern.
{canonicalize_prelude}if printf '%s' "$rel" | grep -qE '{match_bash}'; then
    deny "{message}: $FILE_PATH"
    exit 0
fi

exit 0
"""

# Template for FILE_PATH source, allowlist mode (deny when pattern does NOT match).
# Multi-tool guard uses a case statement.
_BASH_TEMPLATE_FILEPATH_ALLOWLIST = """\
#!/bin/bash
# {id}.sh — PreToolUse hook: {description}.
#
# HOOK-MANIFEST:
# event: {event}
# matcher: {tool_guard}
# surface: {surface}
# signal: {signal}
# role: {role}
# harnesses: {harnesses}
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only guard {tool_guard} tool(s).
case "$TOOL_NAME" in
{tool_guard_case_arms}
*) exit 0 ;;
esac
{agent_type_guard}
# Allowlist: normalise to repo-relative path, then check pattern.
{canonicalize_prelude}if printf '%s' "$rel" | grep -qE '{match_bash}'; then
    exit 0
fi

deny "{message}: $FILE_PATH"
exit 0
"""

# Template for COMMAND source, allowlist mode (default-deny: deny when pattern does NOT match).
# Uses a single tool_guard (Bash only) with optional AGENT_TYPE role guard.
_BASH_TEMPLATE_COMMAND_ALLOWLIST = """\
#!/bin/bash
# {id}.sh — PreToolUse hook: {description}.
#
# HOOK-MANIFEST:
# event: {event}
# matcher: {tool_guard}
# surface: {surface}
# signal: {signal}
# role: {role}
# harnesses: {harnesses}
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
{role_source_prelude}parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard {tool_guard} tool.
if [ "$TOOL_NAME" != "{tool_guard}" ]; then
    exit 0
fi
{bypass_roles_prelude}{agent_type_guard}
# Allowlist: split command into unquoted-chained segments; EVERY segment
# must match the allowlist. Prevents an allowed prefix (e.g. `ls`) chained
# via && / ; / | / & to a forbidden command from bypassing the gate.
if ! _segs=$(split_command_segments "$COMMAND"); then
    deny "{message}"
    exit 0
fi
while IFS= read -r _seg; do
    _trimmed=$(printf '%s' "$_seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$_trimmed" ] && continue
    if ! printf '%s' "$_trimmed" | grep -qE '{match_bash}'; then
        deny "{message}"
        exit 0
    fi
done <<<"$_segs"
exit 0
"""

_BASH_TEMPLATE_ALL = """\
#!/bin/bash
# {id}.sh — PreToolUse hook: {description}.
#
# HOOK-MANIFEST:
# event: {event}
# matcher: {tool_guard}
# surface: {surface}
# signal: {signal}
# role: {role}
# harnesses: {harnesses}
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
{role_source_prelude}parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard {tool_guard} tool.
if [ "$TOOL_NAME" != "{tool_guard}" ]; then
    exit 0
fi
{bypass_roles_prelude}
# Deny: all patterns must match (AND logic).
if {match_all_bash}; then
    deny "{message}"
    exit 0
fi

exit 0
"""


def _bash_escape_message(message):
    """Escape characters that are special inside bash double-quoted strings.

    Backticks trigger command substitution → must be escaped as \\`.
    Dollar signs trigger variable expansion → escape as \\$ (but we don't
    currently have those in denial messages; included for correctness).
    """
    return message.replace("`", r"\`")


# ---------------------------------------------------------------------------
# Role-guard helpers (shared by FILE_PATH + COMMAND branches)
# ---------------------------------------------------------------------------

def _bash_agent_guard(role):
    """Return bash AGENT_TYPE case-guard snippet, or '' for wildcard role."""
    if role and role != "*":
        # Space-pad the pipe join (not bare "|") so each token individually
        # satisfies hook_registrations.py's multi-value role-parity check,
        # which looks for "<token>)" (last token) or "<token> |" (earlier
        # tokens) in the body. A bare "|" join leaves earlier tokens with
        # neither substring present.
        role_case = " | ".join(role.split("|"))
        return (
            f'\n# Only apply to role(s): {role}\n'
            f'case "$AGENT_TYPE" in\n'
            f'{role_case}) ;;\n'
            f'*) exit 0 ;;\n'
            f'esac\n'
        )
    return ""

def _render_bash(entry):
    """Render a bash hook script from a registry entry."""
    eid = entry["id"]
    description = entry.get("description", f"deny {eid} invocations")
    event = entry["event"]
    tool_guard = entry["tool_guard"]
    surface = entry["surface"]
    signal = entry["signal"]
    role = entry["role"]
    harnesses = entry["harnesses"]
    message = _bash_escape_message(entry["message"])

    # New: FILE_PATH source + allowlist mode
    source = entry.get("source", "COMMAND")
    mode = entry.get("mode", "deny")
    canonicalize = entry.get("canonicalize", "")

    if source == "FILE_PATH" and mode == "deny":
        pattern = entry["match"]
        _check_forbidden(pattern, eid)
        match_bash = _to_bash(pattern)

        # Build multi-tool case arms (e.g. "Read|Grep|Glob" → "Read) ;;\nGrep) ;;\nGlob) ;;")
        arms = "\n".join(f"{t}) ;;" for t in tool_guard.split("|"))

        # Canonicalize prelude
        if canonicalize == "repo_relative":
            canon_prelude = 'rel=$(repo_relative "$FILE_PATH")\n'
        else:
            canon_prelude = 'rel="$FILE_PATH"\n'

        agent_guard = _bash_agent_guard(role)

        return _BASH_TEMPLATE_FILEPATH_DENY.format(
            id=eid,
            description=description,
            event=event,
            tool_guard=tool_guard,
            tool_guard_case_arms=arms,
            surface=surface,
            signal=signal,
            role=role,
            harnesses=harnesses,
            message=message,
            match_bash=match_bash,
            canonicalize_prelude=canon_prelude,
            agent_type_guard=agent_guard,
        )

    if source == "FILE_PATH" and mode == "allowlist":
        pattern = entry["match"]
        _check_forbidden(pattern, eid)
        match_bash = _to_bash(pattern)

        # Build multi-tool case arms (e.g. "Write|Edit" → "Write) ;;\nEdit) ;;")
        arms = "\n".join(f"{t}) ;;" for t in tool_guard.split("|"))

        # Canonicalize prelude
        if canonicalize == "repo_relative":
            canon_prelude = 'rel=$(repo_relative "$FILE_PATH")\n'
        else:
            canon_prelude = 'rel="$FILE_PATH"\n'

        agent_guard = _bash_agent_guard(role)

        return _BASH_TEMPLATE_FILEPATH_ALLOWLIST.format(
            id=eid,
            description=description,
            event=event,
            tool_guard=tool_guard,
            tool_guard_case_arms=arms,
            surface=surface,
            signal=signal,
            role=role,
            harnesses=harnesses,
            message=message,
            match_bash=match_bash,
            canonicalize_prelude=canon_prelude,
            agent_type_guard=agent_guard,
        )

    if source == "COMMAND" and mode == "allowlist":
        pattern = entry["match"]
        _check_forbidden(pattern, eid)
        match_bash = _to_bash(pattern)

        agent_guard = _bash_agent_guard(role)

        # bypass_roles prelude
        bypass_roles = entry.get("bypass_roles") or []
        if bypass_roles:
            role_source_prelude = 'source "$(dirname "$0")/_role.sh"\n'
            roles_joined = " ".join(bypass_roles)
            bypass_prelude = (
                f'\n_role=$(resolve_role)\n'
                f'for _m in {roles_joined}; do [ "$_role" = "$_m" ] && exit 0; done\n'
            )
        else:
            role_source_prelude = ""
            bypass_prelude = ""

        return _BASH_TEMPLATE_COMMAND_ALLOWLIST.format(
            id=eid,
            description=description,
            event=event,
            tool_guard=tool_guard,
            surface=surface,
            signal=signal,
            role=role,
            harnesses=harnesses,
            message=message,
            match_bash=match_bash,
            agent_type_guard=agent_guard,
            bypass_roles_prelude=bypass_prelude,
            role_source_prelude=role_source_prelude,
        )

    # Compute bypass_roles prelude for COMMAND+deny and match_all paths.
    bypass_roles = entry.get("bypass_roles") or []
    if bypass_roles:
        role_source_prelude = 'source "$(dirname "$0")/_role.sh"\n'
        roles_joined = " ".join(bypass_roles)
        bypass_prelude = (
            f'\n_role=$(resolve_role)\n'
            f'for _m in {roles_joined}; do [ "$_role" = "$_m" ] && exit 0; done\n'
        )
    else:
        role_source_prelude = ""
        bypass_prelude = ""

    if "match_all" in entry:
        patterns = entry["match_all"]
        for p in patterns:
            _check_forbidden(p, eid)
        bash_patterns = [_to_bash(p) for p in patterns]
        # Build multi-line AND chain matching committed style:
        #   if printf '%s' "$COMMAND" | grep -qE 'P1' &&
        #       printf '%s' "$COMMAND" | grep -qE 'P2'; then
        parts = [f"printf '%s' \"$COMMAND\" | grep -qE '{p}'" for p in bash_patterns]
        match_all_bash = " &&\n    ".join(parts)
        return _BASH_TEMPLATE_ALL.format(
            id=eid,
            description=description,
            event=event,
            tool_guard=tool_guard,
            surface=surface,
            signal=signal,
            role=role,
            harnesses=harnesses,
            message=message,
            match_all_bash=match_all_bash,
            role_source_prelude=role_source_prelude,
            bypass_roles_prelude=bypass_prelude,
        )
    else:
        pattern = entry["match"]
        _check_forbidden(pattern, eid)
        match_bash = _to_bash(pattern)
        agent_guard = _bash_agent_guard(role)
        match_subject = (
            '$(strip_quoted "$COMMAND")' if entry.get("ignore_quoted", False) else "$COMMAND"
        )
        if entry.get("resolve_indirection", False):
            match_subject = f'$(expand_command_indirection "{match_subject}")'
        return _BASH_TEMPLATE_SINGLE.format(
            id=eid,
            description=description,
            event=event,
            tool_guard=tool_guard,
            surface=surface,
            signal=signal,
            role=role,
            harnesses=harnesses,
            message=message,
            match_bash=match_bash,
            match_subject=match_subject,
            role_source_prelude=role_source_prelude,
            bypass_roles_prelude=bypass_prelude,
            agent_type_guard=agent_guard,
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True, help="Path to registry.yaml")
    parser.add_argument("--bash-out", required=True, help="Directory for generated .sh files")
    parser.add_argument("--dry-run", action="store_true", help="Print output, do not write files")
    args = parser.parse_args()

    registry_path = Path(args.registry)
    bash_out = Path(args.bash_out)

    if not registry_path.exists():
        sys.exit(f"ERROR: registry not found: {registry_path}")

    entries = load_registry(registry_path)

    for entry in entries:
        if not entry.get("generated", False):
            continue

        eid = entry.get("id")
        if not eid:
            sys.exit("ERROR: registry entry missing 'id' field")

        # Skip registration-only entries — they have no match/message and their
        # header block is managed by hook_registrations.py --emit-headers, not here.
        if entry.get("kind") == "registration":
            continue

        # Validate match/match_all exclusivity.
        has_match = "match" in entry
        has_match_all = "match_all" in entry
        if has_match and has_match_all:
            sys.exit(f"ERROR: entry '{eid}': both 'match' and 'match_all' present; use one")
        if not has_match and not has_match_all:
            sys.exit(f"ERROR: entry '{eid}': neither 'match' nor 'match_all' present")

        # "all" / "claude" → emit bash. There is one harness, so an entry that
        # names neither is a no-op and stays a loud validation error above.
        harnesses_val = str(entry.get("harnesses", "all"))
        _validate_harnesses(eid, harnesses_val)

        bash_content = _render_bash(entry)
        bash_path = bash_out / f"{eid}.sh"

        if args.dry_run:
            print(f"=== {bash_path} ===")
            print(bash_content)
        else:
            bash_out.mkdir(parents=True, exist_ok=True)
            bash_path.write_text(bash_content)
            # Make bash hook executable.
            bash_path.chmod(bash_path.stat().st_mode | 0o111)
            print(f"generated: {bash_path}")


if __name__ == "__main__":
    main()
