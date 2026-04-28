#!/bin/bash
# static-site-ex-guard.sh — PreToolUse hook for static-site-developer
#
# Blocks Write and Edit tool calls targeting Elixir/HEEX files when the active
# agent is "static-site-developer". All other agents pass through unconditionally.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

# Parse fields from PreToolUse stdin JSON
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging (opt-in via COMBOBULATE_HOOKS_DEBUG flag)
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ]; then
    printf '%s tool=%s agent=%s file=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" "$file_path" \
        >>/tmp/static-site-ex-guard-debug.log 2>/dev/null || true
fi

# Only gate static-site-developer; allow all other agents unconditionally
if [ "$agent_type" != "static-site-developer" ]; then
    exit 0
fi

# Block Write or Edit calls targeting Elixir/HEEX files
if [ "$tool_name" = "Write" ] || [ "$tool_name" = "Edit" ]; then
    if printf '%s' "$file_path" | grep -qE '\.(ex|exs|heex)$'; then
        printf 'BLOCKED by static-site-ex-guard: static-site-developer cannot edit Elixir/HEEX files (%s). Re-delegate to phoenix-developer.\n' "$file_path" >&2
        exit 2
    fi
fi

exit 0
