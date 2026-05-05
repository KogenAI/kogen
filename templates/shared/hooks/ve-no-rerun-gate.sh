#!/bin/bash
# ve-no-rerun-gate.sh — PreToolUse Bash hook scoped to verification-engineer.
#
# Blocks a second invocation of the gate command (make ci, make ci-fast,
# make llm, make llm-phoenix, mix test) from the same agent_id.
# VE should read the log file instead of re-running.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log ve-no-rerun-gate "tool=$TOOL_NAME agent_type=$AGENT_TYPE agent_id=$AGENT_ID"

# Only gate verification-engineer
if [ "$AGENT_TYPE" != "verification-engineer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only gate gate-running commands
if ! printf '%s' "$COMMAND" | grep -qE '\bmake[[:space:]]+ci([[:space:]]|$)|\bmake[[:space:]]+ci-fast([[:space:]]|$)|\bmake[[:space:]]+llm([[:space:]]|$)|\bmake[[:space:]]+llm-phoenix([[:space:]]|$)|\bmix[[:space:]]+test\b'; then
    exit 0
fi

# Use agent_id to track per-agent gate history.
history_file="/tmp/ve-gate-history-${AGENT_ID}"

# Normalise: trim leading/trailing whitespace, collapse internal whitespace runs
# to a single space.
normalised_cmd=$(printf '%s' "$COMMAND" | awk '{$1=$1; print}')

if [ -f "$history_file" ]; then
    while IFS= read -r prev_cmd; do
        [ -z "$prev_cmd" ] && continue
        if [ "$prev_cmd" = "$normalised_cmd" ]; then
            deny "BLOCKED by ve-no-rerun-gate: VE already ran the exact gate command. Read the log file instead, or narrow to a specific test file. To re-run, dispatch a new VE delegation."
            exit 0
        fi
    done <"$history_file"
fi

# Record this invocation
printf '%s\n' "$normalised_cmd" >>"$history_file" 2>/dev/null || true

exit 0
