#!/bin/bash
# ve-gate-prompt-validator.sh — SubagentStart hook scoped to verification-engineer.
#
# Validates that the inbound delegation prompt begins with "Gate: <command>"
# on the first non-empty line. If not, the VE subagent is blocked before
# it even starts, and the orchestrator sees the error inline.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log ve-gate-prompt-validator "agent_type=$AGENT_TYPE"

# Only gate verification-engineer
if [ "$AGENT_TYPE" != "verification-engineer" ]; then
    exit 0
fi

# Find the first non-empty line of the prompt
first_nonempty=$(printf '%s' "$PROMPT" | grep -m1 '[^[:space:]]' || true)

if printf '%s' "$first_nonempty" | grep -qE '^Gate:[[:space:]]'; then
    exit 0
fi

deny 'BLOCKED by ve-gate-prompt-validator: VE delegation must begin with "Gate: <command>" on the first line. See verification-engineer template § "Refuse without Gate".'
exit 0
