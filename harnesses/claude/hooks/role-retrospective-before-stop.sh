#!/usr/bin/env bash
# role-retrospective-before-stop.sh — Stop hook that blocks a planner/developer/
# reviewer from stopping until this cycle's log carries BOTH its work
# (an {"ev":"role"} event with a non-empty body) AND its learning (an
# {"ev":"learned"} event clearing the non-triviality bar).
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: AGENT_TYPE
# role: planner-*|developer-*|reviewer-*
# harnesses: all
# rationale: Blocks a planner/developer/reviewer Stop until the cycle log carries both its work (ev:role body) and its learning (ev:learned). Pi twin is observe-only (session_shutdown cannot block).
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Never fatal: bounded at 3 blocks per session, then removes its counter,
# warns loudly on stderr, and allows the stop.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

session_id="${SESSION_ID:-unknown}"
counter_file="/tmp/claude-retro-${session_id}.count"

debug_log role-retrospective-before-stop "session=$session_id agent_type=${AGENT_TYPE:-}"

if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log role-retrospective-before-stop "skip: stop_hook_active"
    exit 0
fi

# Role gate — planner-*, developer-*, reviewer-* only.
# (context-curator and committer are NOT gated.)
case "${AGENT_TYPE:-}" in
planner-* | developer-* | reviewer-*) ;;
*)
    debug_log role-retrospective-before-stop "skip: agent_type=${AGENT_TYPE:-} not gated"
    exit 0
    ;;
esac

log_file=$(session_log_from_transcript)
if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
    debug_log role-retrospective-before-stop "skip: no cycle log resolved"
    exit 0
fi

# --- Work presence: an ev:role event with a non-empty body ------------------
work_body=$(jq -r --arg r "$AGENT_TYPE" \
    'select(.ev=="role" and .role==$r)|.body' "$log_file" 2>/dev/null |
    grep -v '^[[:space:]]*$' | head -1)

# --- Learning presence: an ev:learned event clearing the triviality bar -----
learned_text=$(jq -r --arg r "$AGENT_TYPE" \
    'select(.ev=="learned" and .role==$r)|.text' "$log_file" 2>/dev/null |
    tr '\n' ' ')

retro_ok=0
if [ -n "$learned_text" ]; then
    trimmed=$(printf '%s' "$learned_text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    normalized=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]' | tr -d '.-')
    if [ "${#trimmed}" -ge 40 ]; then
        case "$normalized" in
        'nothing notable' | 'nothing' | 'none' | 'n/a' | 'no learnings') ;;
        *) retro_ok=1 ;;
        esac
    fi
fi

missing=""
[ -z "$work_body" ] && missing="work"
[ "$retro_ok" = "0" ] && missing="${missing:+${missing} and }learning"

if [ -z "$missing" ]; then
    rm -f "$counter_file"
    debug_log role-retrospective-before-stop "allow: work + learning present"
    exit 0
fi

# --- Bounded block ------------------------------------------------------------
count=0
[ -r "$counter_file" ] && count=$(cat "$counter_file" 2>/dev/null || echo 0)
case "$count" in
'' | *[!0-9]*) count=0 ;;
esac

if [ "$count" -ge 3 ]; then
    rm -f "$counter_file"
    printf 'role-retrospective-before-stop: %s stopped without recording its %s after 3 attempts — proceeding without it\n' \
        "$AGENT_TYPE" "$missing" >&2
    exit 0
fi

count=$((count + 1))
printf '%s' "$count" >"$counter_file"

if [ -z "$work_body" ]; then
    reason="You have not recorded your work this step. Run: printf '%s' \"\$body\" | codegen-log section ${AGENT_TYPE} --learned \"<what you learned>\" --slug <slug> — then stop. (attempt ${count}/3)"
else
    reason="You have not recorded what you learned this step. Run: codegen-log append ${AGENT_TYPE} --learned \"<text>\" --slug <slug> — at least 40 characters, no placeholders ('nothing notable', 'none', 'n/a'). Then stop. (attempt ${count}/3)"
fi

block "$reason"
exit 0
