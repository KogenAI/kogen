#!/usr/bin/env bash
# stop-verify-planner-gate.sh — Stop hook that blocks a planner subagent from
# stopping when the active step log is missing its typed {"ev":"plan_gate",...}
# gate SELECTION event or its typed {"ev":"plan",...} PLAN event.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: AGENT_TYPE
# role: planner-*
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks Stop when:
#   AGENT_TYPE matches planner-* AND the active step log resolved from the
#   transcript has a missing or placeholder gate selection (via the typed
#   {"ev":"plan_gate",...} event, `codegen-log append <role> --plan-gate @-`),
#   OR is missing its typed {"ev":"plan",...} plan event
#   (`codegen-log append <role> --plan @-`). Neither is re-parsed out of the
#   free-form ev:role body prose — see session-log.md § the body is opaque,
#   never re-parsed as structure.
#
# Skip when:
#   - STOP_HOOK_ACTIVE=true (recursion guard)
#   - TRANSCRIPT_PATH unset or unreadable
#   - AGENT_TYPE does not match planner-*
#   - No step log resolved from transcript
#   - Both the gate selection and the plan event are present and non-placeholder
#
# Placeholder denylist (case-insensitive), applied to the gate command:
#   ^(TBD|pending|<.*>|to be determined|todo)$

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/lib/gate-select.sh"
parse_input

session_id="${SESSION_ID:-unknown}"

debug_log stop-verify-planner-gate "session=$session_id agent_type=$AGENT_TYPE"

# Recursion guard
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log stop-verify-planner-gate "skip: stop_hook_active"
    exit 0
fi

# Only enforce for planner-* subagents
case "${AGENT_TYPE:-}" in
planner-*) ;;
*)
    debug_log stop-verify-planner-gate "skip: agent_type=$AGENT_TYPE is not planner-*"
    exit 0
    ;;
esac

# Transcript guard — cannot inspect without transcript
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log stop-verify-planner-gate "skip: no transcript"
    exit 0
fi

# Resolve active step log from transcript
log_file=$(session_log_from_transcript)

if [ -z "$log_file" ]; then
    debug_log stop-verify-planner-gate "skip: no step log found in transcript"
    exit 0
fi

debug_log stop-verify-planner-gate "resolved log=$log_file"

# Read the typed gate SELECTION event ({"ev":"plan_gate",...}).
gate_value=$(gate_select_read_planner_gate "$log_file")

debug_log stop-verify-planner-gate "gate_value=$gate_value"

# Block if gate is empty
if [ -z "$gate_value" ]; then
    reason="stop-verify-planner-gate: planner stopped with no {\"ev\":\"plan_gate\"} event in ${log_file}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare the exact gate command before Stop. Write it via \`codegen-log append <role> --plan-gate @-\`, then return."
    debug_log stop-verify-planner-gate "BLOCK: gate empty"
    block "$reason"
    exit 0
fi

# Block if gate matches placeholder denylist (case-insensitive)
gate_lower=$(printf '%s' "$gate_value" | tr '[:upper:]' '[:lower:]')
if printf '%s' "$gate_lower" | grep -qE '^(tbd|pending|to be determined|todo)$' ||
    printf '%s' "$gate_value" | grep -qE '^<.*>$'; then
    reason="stop-verify-planner-gate: planner stopped with a placeholder gate command (${gate_value}) in the {\"ev\":\"plan_gate\"} event of ${log_file}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare the exact gate command before Stop. Write it via \`codegen-log append <role> --plan-gate @-\`, then return."
    debug_log stop-verify-planner-gate "BLOCK: gate is placeholder ($gate_value)"
    block "$reason"
    exit 0
fi

# Read the typed PLAN event ({"ev":"plan",...}). The plan is a typed marker
# — never re-parsed out of the free-form ev:role body prose (session-log.md
# § the body is opaque, never re-parsed as structure).
plan_value=$(gate_select_read_planner_plan "$log_file")
plan_trimmed=$(printf '%s' "$plan_value" | tr -d '[:space:]')

debug_log stop-verify-planner-gate "plan_present=$([ -n "$plan_trimmed" ] && printf yes || printf no)"

if [ -z "$plan_trimmed" ]; then
    reason="stop-verify-planner-gate: planner stopped with no {\"ev\":\"plan\"} event in ${log_file} — write your plan via 'codegen-log append <role> --plan @-' before stopping."
    debug_log stop-verify-planner-gate "BLOCK: plan event absent"
    block "$reason"
    exit 0
fi

debug_log stop-verify-planner-gate "allow: gate=$gate_value plan_present=yes"
exit 0
