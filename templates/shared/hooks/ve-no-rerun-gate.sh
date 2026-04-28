#!/bin/bash
# ve-no-rerun-gate.sh — PreToolUse Bash hook scoped to verification-engineer.
#
# Blocks a second invocation of the gate command (make ci, make ci-fast,
# make llm, make llm-phoenix, mix test) from the same agent_id.
# VE should read the log file instead of re-running.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_VNRG_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s agent_id=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" "$agent_id" \
        >>/tmp/ve-no-rerun-gate-debug.log 2>/dev/null || true
fi

# Only gate verification-engineer
if [ "$agent_type" != "verification-engineer" ]; then
    exit 0
fi

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only gate gate-running commands
if ! printf '%s' "$command" | grep -qE '\bmake[[:space:]]+ci\b|\bmake[[:space:]]+ci-fast\b|\bmake[[:space:]]+llm\b|\bmake[[:space:]]+llm-phoenix\b|\bmix[[:space:]]+test\b'; then
    exit 0
fi

# Use agent_id to track per-agent gate history
history_file="/tmp/ve-gate-history-${agent_id}"

if [ -f "$history_file" ]; then
    printf 'BLOCKED by ve-no-rerun-gate: VE already ran the gate. Read the log file instead. To re-run, dispatch a new VE delegation.\n' >&2
    exit 2
fi

# First invocation — create the tracking file
touch "$history_file" 2>/dev/null || true

exit 0
