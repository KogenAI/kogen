#!/bin/bash
# ve-no-stash-guard.sh — PreToolUse Bash hook scoped to verification-engineer.
#
# Blocks git stash for verification-engineer. Pre-existence of a failure
# is irrelevant — every failure on the current branch must be reported.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_VNSG_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/ve-no-stash-guard-debug.log 2>/dev/null || true
fi

# Only gate verification-engineer
if [ "$agent_type" != "verification-engineer" ]; then
    exit 0
fi

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+stash\b'; then
    printf 'BLOCKED by ve-no-stash-guard: git stash is forbidden for verification-engineer. Pre-existence of a failure is irrelevant — every failure on this branch must be reported.\n' >&2
    exit 2
fi

exit 0
