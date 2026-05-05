#!/bin/bash
# ve-no-stash-guard.sh — PreToolUse Bash hook scoped to verification-engineer.
#
# Blocks git stash for verification-engineer. Pre-existence of a failure
# is irrelevant — every failure on the current branch must be reported.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log ve-no-stash-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate verification-engineer
if [ "$AGENT_TYPE" != "verification-engineer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+stash\b'; then
    deny "BLOCKED by ve-no-stash-guard: git stash is forbidden for verification-engineer. Pre-existence of a failure is irrelevant — every failure on this branch must be reported."
    exit 0
fi

exit 0
