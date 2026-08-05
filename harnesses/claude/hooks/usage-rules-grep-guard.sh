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
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks every agent except the developer from grepping/scanning
# codegen/usage_rules/. Only the developer may scan the full corpus — every
# other agent must read only files cited by codegen/usage_rules/INDEX.md.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log usage-rules-grep-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Developer may scan usage_rules freely
case "$AGENT_TYPE" in
developer-*)
    exit 0
    ;;
esac

case "$TOOL_NAME" in
Bash)
    if printf '%s' "$COMMAND" | grep -qE '(grep|rg)[[:space:]]+.*codegen/usage_rules/'; then
        deny 'BLOCKED by usage-rules-grep-guard: only the developer may scan codegen/usage_rules/. Read codegen/usage_rules/INDEX.md, look up the deps you are touching, and Read at most 5 cited files.'
        exit 0
    fi
    ;;
Grep)
    path=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.path // ""')
    if printf '%s' "$path" | grep -q 'codegen/usage_rules'; then
        deny 'BLOCKED by usage-rules-grep-guard: only the developer may scan codegen/usage_rules/. Read codegen/usage_rules/INDEX.md, look up the deps you are touching, and Read at most 5 cited files.'
        exit 0
    fi
    ;;
esac

exit 0
