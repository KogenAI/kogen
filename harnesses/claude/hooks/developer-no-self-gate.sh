#!/bin/bash
# developer-no-self-gate.sh — PreToolUse Bash hook for developer-* agents.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Counts CI/test invocations per session. Once the counter reaches 3,
# denies further attempts and instructs the dev to hand off to the
# orchestrator via dev-gate.sh.
#
# Tracked patterns:
#   mix test, mix credo, mix format
#   make ci, make test

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log developer-no-self-gate "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate developer-* variants
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | developer-static) ;;
*)
    exit 0
    ;;
esac

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Check if command matches a self-gate pattern
if ! printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+(test|credo|format)\b|\bmake[[:space:]]+(ci|test)\b'; then
    exit 0
fi

# mix credo is cheap and required before handoff — bypass the cap entirely.
# Only mix test / make ci / make test / mix format remain capped.
if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+credo\b' &&
    ! printf '%s' "$COMMAND" | grep -qE '\bmake[[:space:]]+(ci|test)\b|\bmix[[:space:]]+test\b'; then
    exit 0
fi

session_id="${SESSION_ID:-unknown}"
counter_file="/tmp/codegen-self-gate-${session_id}.count"

# Read current count
count=0
if [ -r "$counter_file" ]; then
    count=$(cat "$counter_file" 2>/dev/null || echo 0)
fi
case "$count" in
'' | *[!0-9]*) count=0 ;;
esac

# Increment
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

debug_log developer-no-self-gate "session=$session_id count=$count cmd=$COMMAND"

if [ "$count" -ge 3 ]; then
    deny "BLOCKED by developer-no-self-gate: use dev-gate.sh handoff — return control to orchestrator. You have run CI/test commands $count times in this session. Complete your implementation and stop — the gate runs automatically via SubagentStop hook."
    exit 0
fi

exit 0
