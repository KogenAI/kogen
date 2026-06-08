#!/bin/bash
# usage-rules-grep-guard.sh — PreToolUse Bash|Grep hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Grep
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks non-planner agents from grepping/scanning codegen/usage_rules/.
# Only the planner may scan the full corpus — all other agents must read
# only the files cited in the plan's "Usage rules for implementer:" field.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log usage-rules-grep-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Planner may scan usage_rules freely
if [ "$AGENT_TYPE" = "planner" ]; then
    exit 0
fi

case "$TOOL_NAME" in
Bash)
    if printf '%s' "$COMMAND" | grep -qE '(grep|rg)[[:space:]]+.*codegen/usage_rules/'; then
        deny 'BLOCKED by usage-rules-grep-guard: only planner may scan codegen/usage_rules/. Read only the files cited in the plan'"'"'s "Usage rules for implementer:" field.'
        exit 0
    fi
    ;;
Grep)
    path=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.path // ""')
    if printf '%s' "$path" | grep -q 'codegen/usage_rules'; then
        deny 'BLOCKED by usage-rules-grep-guard: only planner may scan codegen/usage_rules/. Read only the files cited in the plan'"'"'s "Usage rules for implementer:" field.'
        exit 0
    fi
    ;;
esac

exit 0
