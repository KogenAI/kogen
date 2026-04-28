#!/bin/bash
# usage-rules-grep-guard.sh — PreToolUse Bash|Grep hook.
#
# Blocks non-planner agents from grepping/scanning codegen/usage_rules/.
# Only the planner may scan the full corpus — all other agents must read
# only the files cited in the plan's "Usage rules for implementer:" field.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_URGG_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/usage-rules-grep-guard-debug.log 2>/dev/null || true
fi

# Planner may scan usage_rules freely
if [ "$agent_type" = "planner" ]; then
    exit 0
fi

case "$tool_name" in
Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    if printf '%s' "$command" | grep -qE '(grep|rg)[[:space:]]+.*codegen/usage_rules/'; then
        printf 'BLOCKED by usage-rules-grep-guard: only planner may scan codegen/usage_rules/. Read only the files cited in the plan'"'"'s "Usage rules for implementer:" field.\n' >&2
        exit 2
    fi
    ;;
Grep)
    path=$(printf '%s' "$input" | jq -r '.tool_input.path // ""')
    if printf '%s' "$path" | grep -q 'codegen/usage_rules'; then
        printf 'BLOCKED by usage-rules-grep-guard: only planner may scan codegen/usage_rules/. Read only the files cited in the plan'"'"'s "Usage rules for implementer:" field.\n' >&2
        exit 2
    fi
    ;;
esac

exit 0
