#!/bin/bash
# developer-no-self-gate-reset.sh — SubagentStop sibling to developer-no-self-gate.sh.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend|developer-html|developer-hugo|developer-vite
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Removes the per-session counter file when a developer subagent stops,
# so the next invocation of the same session starts with a clean count.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log developer-no-self-gate-reset "agent=$AGENT_TYPE session=$SESSION_ID"

# Only act on developer-* variants
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | developer-html | developer-hugo | developer-vite) ;;
*)
    exit 0
    ;;
esac

session_id="${SESSION_ID:-unknown}"
counter_file="/tmp/codegen-self-gate-${session_id}.count"

if [ -f "$counter_file" ]; then
    rm -f "$counter_file"
    debug_log developer-no-self-gate-reset "removed counter_file=$counter_file"
fi

exit 0
