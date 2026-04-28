#!/bin/bash
# commit-only-via-committer.sh — PreToolUse Bash hook.
#
# Blocks git commit from any agent that is NOT the committer subagent.
# This enforces the rule that all commits go through the committer role,
# including from the orchestrator (which has an empty agent_id).
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_COVC_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/commit-only-via-committer-debug.log 2>/dev/null || true
fi

# Only gate Bash tool
if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only inspect git commit commands
if ! printf '%s' "$command" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

# Committer is allowed
if [ "$agent_type" = "committer" ]; then
    exit 0
fi

printf 'BLOCKED by commit-only-via-committer: Use the committer subagent — orchestrator and non-committer subagents must not commit directly. Delegate to committer with the task summary.\n' >&2
exit 2
