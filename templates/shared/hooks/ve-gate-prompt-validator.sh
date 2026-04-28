#!/bin/bash
# ve-gate-prompt-validator.sh — SubagentStart hook scoped to verification-engineer.
#
# Validates that the inbound delegation prompt begins with "Gate: <command>"
# on the first non-empty line. If not, the VE subagent is blocked before
# it even starts, and the orchestrator sees the error inline.
#
# Exit codes:
#   0 — allow (prompt begins with Gate:)
#   2 — block (Claude Code SubagentStart convention; stderr fed back to orchestrator)

set -euo pipefail

input=$(cat)

agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_VGPV_DEBUG:-}" ]; then
    printf '%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$agent_type" \
        >>/tmp/ve-gate-prompt-validator-debug.log 2>/dev/null || true
fi

# Only gate verification-engineer
if [ "$agent_type" != "verification-engineer" ]; then
    exit 0
fi

# Extract the prompt field
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""')

# Find the first non-empty line
first_nonempty=$(printf '%s' "$prompt" | grep -m1 '[^[:space:]]' || true)

if printf '%s' "$first_nonempty" | grep -qE '^Gate:[[:space:]]'; then
    exit 0
fi

printf 'BLOCKED by ve-gate-prompt-validator: VE delegation must begin with "Gate: <command>" on the first line. See verification-engineer template § "Refuse without Gate".\n' >&2
exit 2
