#!/usr/bin/env python3
"""enforcement_compiler.py — generate bash + TypeScript denial hooks from registry.yaml.

Usage:
    python3 enforcement_compiler.py \\
        --registry shared/enforcement/registry.yaml \\
        --bash-out harnesses/claude/hooks \\
        --ts-out harnesses/pi/pi-extensions/enforcement/src/hooks \\
        --index harnesses/pi/pi-extensions/enforcement/src/index.ts

For each entry with generated: true the compiler:
  - Emits a bash hook to <bash-out>/<id>.sh
  - Emits a TypeScript hook to <ts-out>/<id>.ts
  - Updates the GENERATED-ENFORCEMENT-BLOCK markers in <index>

Pattern dialect translation:
  Registry uses regex-neutral syntax (\\s, \\b, etc.)
  Bash (ERE):  \\s → [[:space:]]
  TypeScript:  \\s → \\s  (pass-through; JS already uses \\s)

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


def _to_ts(pattern):
    r"""Translate registry regex-neutral pattern to TypeScript/JS regex body.

    \\s stays \\s — JS already uses \\s.
    All other tokens pass through.
    """
    return pattern


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
parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard {tool_guard} tool.
if [ "$TOOL_NAME" != "{tool_guard}" ]; then
    exit 0
fi

# Deny: pattern match.
if printf '%s' "$COMMAND" | grep -qE '{match_bash}'; then
    deny "{message}"
    exit 0
fi

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
parse_input

debug_log {id} "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard {tool_guard} tool.
if [ "$TOOL_NAME" != "{tool_guard}" ]; then
    exit 0
fi

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
        )
    else:
        pattern = entry["match"]
        _check_forbidden(pattern, eid)
        match_bash = _to_bash(pattern)
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
        )


# ---------------------------------------------------------------------------
# TypeScript hook generation
# ---------------------------------------------------------------------------

_TS_TEMPLATE_SINGLE = """\
/**
 * {id}.ts — Pi enforcement: {description}.
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type {{ ExtensionAPI }} from "@earendil-works/pi-coding-agent";
import {{ deny, debugLog }} from "../lib/hook-helpers";

export const HANDLER_META = {{
  name: "{id}",
  event: "tool_call",
  matcher: "bash",
}} as const;

export function register(pi: ExtensionAPI): void {{
  pi.on("tool_call", async (event) => {{
    if (event.toolName !== "bash") return;

    const command: string = (event.input as {{ command?: string }}).command ?? "";
    debugLog("{id}", `cmd=${{command}}`);

    if (/{match_ts}/.test(command)) {{
      return deny(
        "{message}",
      );
    }}
  }});
}}
"""

_TS_TEMPLATE_ALL = """\
/**
 * {id}.ts — Pi enforcement: {description}.
 *
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 *
 * GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
 * Edit registry.yaml and run `make install` to regenerate.
 */

import type {{ ExtensionAPI }} from "@earendil-works/pi-coding-agent";
import {{ deny, debugLog }} from "../lib/hook-helpers";

export const HANDLER_META = {{
  name: "{id}",
  event: "tool_call",
  matcher: "bash",
}} as const;

export function register(pi: ExtensionAPI): void {{
  pi.on("tool_call", async (event) => {{
    if (event.toolName !== "bash") return;

    const command: string = (event.input as {{ command?: string }}).command ?? "";
    debugLog("{id}", `cmd=${{command}}`);

    if (
      {match_all_ts}
    ) {{
      return deny(
        "{message}",
      );
    }}
  }});
}}
"""


def _render_ts(entry):
    """Render a TypeScript hook module from a registry entry."""
    eid = entry["id"]
    description = entry.get("description", f"deny {eid} invocations")
    message = entry["message"]

    if "match_all" in entry:
        patterns = entry["match_all"]
        for p in patterns:
            _check_forbidden(p, eid)
        ts_patterns = [_to_ts(p) for p in patterns]
        # Build multi-line AND chain matching prettier 4-line if format:
        #   if (
        #     /P1/.test(command) &&
        #     /P2/.test(command)
        #   ) {
        parts = [f"/{p}/.test(command)" for p in ts_patterns]
        match_all_ts = " &&\n      ".join(parts)
        return _TS_TEMPLATE_ALL.format(
            id=eid,
            description=description,
            message=message,
            match_all_ts=match_all_ts,
        )
    else:
        pattern = entry["match"]
        _check_forbidden(pattern, eid)
        match_ts = _to_ts(pattern)
        return _TS_TEMPLATE_SINGLE.format(
            id=eid,
            description=description,
            message=message,
            match_ts=match_ts,
        )


# ---------------------------------------------------------------------------
# index.ts update
# ---------------------------------------------------------------------------

_BLOCK_START = "// BEGIN-GENERATED-ENFORCEMENT-BLOCK"
_BLOCK_END = "// END-GENERATED-ENFORCEMENT-BLOCK"


def _camel(slug):
    """Convert kebab-slug to camelCase register alias.

    no-cat-pipe → NoCatPipe → registerNoCatPipe
    """
    parts = slug.split("-")
    title = "".join(p.capitalize() for p in parts)
    return f"register{title}"


def _update_index(index_path, generated_ids):
    """Insert or replace the generated enforcement block in index.ts.

    The block is bounded by:
      // BEGIN-GENERATED-ENFORCEMENT-BLOCK
      ...
      // END-GENERATED-ENFORCEMENT-BLOCK

    Handles two cases:
      1. Markers already present → replace block contents in-place.
      2. No markers → find existing hand-written lines for generated IDs,
         remove them, and insert a marked block in their place.

    generated_ids is used to locate existing lines; sorted alphabetically
    so the block is deterministic.
    """
    content = Path(index_path).read_text()

    # Build import lines and register call lines for generated IDs (sorted).
    sorted_ids = sorted(generated_ids)
    import_lines = []
    register_lines = []
    for eid in sorted_ids:
        alias = _camel(eid)
        import_lines.append(
            f'import {{ register as {alias} }} from "./hooks/{eid}";'
        )
        register_lines.append(f"  {alias}(pi);")

    import_block = (
        _BLOCK_START + "\n"
        + "\n".join(import_lines) + "\n"
        + _BLOCK_END
    )

    register_block = (
        "  " + _BLOCK_START + "\n"
        + "\n".join(register_lines) + "\n"
        + "  " + _BLOCK_END
    )

    if _BLOCK_START in content:
        # Find all block spans (including any leading indentation) and replace.
        # The leading [ \t]* is consumed by the match so replacements supply
        # their own indentation: import block = 0 spaces, register block = 2.
        block_re = re.compile(
            r"[ \t]*" + re.escape(_BLOCK_START) + r".*?" + re.escape(_BLOCK_END),
            flags=re.DOTALL,
        )
        matches = list(block_re.finditer(content))
        replacements = [import_block, register_block]
        # Pair matches with replacements (by position order).
        pairs = list(zip(matches, replacements))
        # Apply in reverse order so earlier offsets stay valid.
        for m, replacement in reversed(pairs):
            content = content[:m.start()] + replacement + content[m.end():]
    else:
        # No markers yet — replace the first hand-written import line with the
        # whole import block, then remove remaining individual import lines.
        # Similarly for register calls.
        aliases = [_camel(eid) for eid in sorted_ids]
        alias_re = "|".join(re.escape(a) for a in aliases)
        id_re = "|".join(re.escape(eid) for eid in sorted_ids)

        # Pattern for a single generated import line (with trailing newline).
        import_line_re = re.compile(
            r'^import \{ register as (?:' + alias_re + r') \} from "./hooks/(?:' + id_re + r')";\n',
            re.MULTILINE,
        )
        # Pattern for a single generated register call (with trailing newline).
        register_line_re = re.compile(
            r'^  (?:' + alias_re + r')\(pi\);\n',
            re.MULTILINE,
        )

        # Strategy: find all matching import lines, note the span of the first,
        # replace the entire group with the import_block.
        # Do the same for register call lines.

        # Collect all import match positions.
        import_matches = list(import_line_re.finditer(content))
        if import_matches:
            # Replace region from first match start to last match end with block.
            block_start = import_matches[0].start()
            block_end = import_matches[-1].end()
            content = content[:block_start] + import_block + "\n" + content[block_end:]

        # Collect all register call match positions (re-search after import update).
        register_matches = list(register_line_re.finditer(content))
        if register_matches:
            block_start = register_matches[0].start()
            block_end = register_matches[-1].end()
            content = content[:block_start] + register_block + "\n" + content[block_end:]

    Path(index_path).write_text(content)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True, help="Path to registry.yaml")
    parser.add_argument("--bash-out", required=True, help="Directory for generated .sh files")
    parser.add_argument("--ts-out", required=True, help="Directory for generated .ts files")
    parser.add_argument("--index", required=True, help="Path to index.ts to update")
    parser.add_argument("--dry-run", action="store_true", help="Print output, do not write files")
    args = parser.parse_args()

    registry_path = Path(args.registry)
    bash_out = Path(args.bash_out)
    ts_out = Path(args.ts_out)
    index_path = Path(args.index)

    if not registry_path.exists():
        sys.exit(f"ERROR: registry not found: {registry_path}")

    entries = load_registry(registry_path)

    generated_ids = []

    for entry in entries:
        if not entry.get("generated", False):
            continue

        eid = entry.get("id")
        if not eid:
            sys.exit("ERROR: registry entry missing 'id' field")

        # Validate match/match_all exclusivity.
        has_match = "match" in entry
        has_match_all = "match_all" in entry
        if has_match and has_match_all:
            sys.exit(f"ERROR: entry '{eid}': both 'match' and 'match_all' present; use one")
        if not has_match and not has_match_all:
            sys.exit(f"ERROR: entry '{eid}': neither 'match' nor 'match_all' present")

        bash_content = _render_bash(entry)
        ts_content = _render_ts(entry)

        bash_path = bash_out / f"{eid}.sh"
        ts_path = ts_out / f"{eid}.ts"

        if args.dry_run:
            print(f"=== {bash_path} ===")
            print(bash_content)
            print(f"=== {ts_path} ===")
            print(ts_content)
        else:
            bash_out.mkdir(parents=True, exist_ok=True)
            ts_out.mkdir(parents=True, exist_ok=True)
            bash_path.write_text(bash_content)
            ts_path.write_text(ts_content)
            # Make bash hook executable.
            bash_path.chmod(bash_path.stat().st_mode | 0o111)
            print(f"generated: {bash_path}")
            print(f"generated: {ts_path}")

        generated_ids.append(eid)

    if not args.dry_run and generated_ids:
        _update_index(index_path, generated_ids)
        print(f"updated:   {index_path}")


if __name__ == "__main__":
    main()
