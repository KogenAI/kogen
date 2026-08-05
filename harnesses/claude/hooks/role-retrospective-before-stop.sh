#!/usr/bin/env bash
# role-retrospective-before-stop.sh — Stop hook that blocks a developer/
# reviewer from stopping until this cycle's log carries BOTH its work
# (an {"ev":"role"} event with a non-empty body) AND its learning — either
# an {"ev":"learned"} event or an {"ev":"no_learning"} event (the legal,
# countable "this turn produced nothing to learn" exit). Substance (not
# length) is enforced at the writer — codegen-log refuses a placeholder or
# compliance-echo text before it ever reaches the log; this hook only checks
# PRESENCE of one of the two event kinds.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*|reviewer-*
# harnesses: all
# rationale: Blocks a developer/reviewer Stop until the cycle log carries both its work (ev:role body) and either its learning (ev:learned) or an explicit ev:no_learning. Substance (not length) is enforced at the writer — codegen-log refuses placeholder/compliance-echo text. Pi twin is observe-only (session_shutdown cannot block).
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
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

# Role gate — developer-*, reviewer-* only.
# (context-curator and committer are NOT gated.)
case "${AGENT_TYPE:-}" in
developer-* | reviewer-*) ;;
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

# --- Learning presence: EITHER an ev:learned OR an ev:no_learning event for
# this role. Substance is enforced at the writer (codegen-log refuses
# placeholder/compliance-echo text before it lands) — this hook checks
# presence only, never re-judges content quality.
retro_ok=0
if jq -e --arg r "$AGENT_TYPE" \
    'select((.ev=="learned" or .ev=="no_learning") and .role==$r)' \
    "$log_file" >/dev/null 2>&1; then
    retro_ok=1
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
    reason="You have not recorded your work this step. Run: printf '%s' \"\$body\" | codegen-log section ${AGENT_TYPE} --learned \"[local] <what you learned>\" --slug <slug> — then stop. (attempt ${count}/3)"
else
    reason="You have not recorded what you learned this step. Record one specific thing this turn taught you — a fact a future session would look up. If this turn genuinely produced nothing to learn, say so: codegen-log append ${AGENT_TYPE} --no-learning \"<what the turn did instead>\" --slug <slug>. (attempt ${count}/3)"
fi

block "$reason"
exit 0
