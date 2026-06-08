#!/usr/bin/env bash
# stop-verify-planner-gate.sh — Stop hook that blocks a planner subagent from
# stopping when the active step log has a missing or placeholder **Gate**: value.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: AGENT_TYPE
# role: planner-*
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks Stop when:
#   AGENT_TYPE matches planner-* AND the active step log resolved from the
#   transcript has a missing or placeholder **Gate**: value in ## Plan.
#
# Skip when:
#   - STOP_HOOK_ACTIVE=true (recursion guard)
#   - TRANSCRIPT_PATH unset or unreadable
#   - AGENT_TYPE does not match planner-*
#   - No step log resolved from transcript
#   - **Gate**: is present and not a placeholder value
#
# Placeholder denylist (case-insensitive):
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

# Extract **Gate**: value from ## Plan section
gate_value=$(gate_select_read_planner_gate "$log_file")

debug_log stop-verify-planner-gate "gate_value=$gate_value"

# Block if gate-json block parse error
case "$gate_value" in
__GATE_PARSE_ERROR__:*)
    parse_reason="${gate_value#__GATE_PARSE_ERROR__:}"
    reason="stop-verify-planner-gate: planner stopped with a malformed \`\`\`gate-json block in \`## Plan\` of ${log_file}: ${parse_reason}. Fix the gate-json block so it is valid JSON with required fields command, mode, timeout (all strings/integers), then return."
    debug_log stop-verify-planner-gate "BLOCK: gate-json parse error: $parse_reason"
    block "$reason"
    exit 0
    ;;
esac

# Block if gate is empty
if [ -z "$gate_value" ]; then
    reason="stop-verify-planner-gate: planner stopped with \`**Gate**:\` missing or placeholder in \`## Plan\` of ${log_file}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare exact gate command before Stop. Edit step log to set a \`\`\`gate-json block or \`**Gate**: <make target>\` inside ## Plan, then return."
    debug_log stop-verify-planner-gate "BLOCK: gate empty"
    block "$reason"
    exit 0
fi

# Block if gate matches placeholder denylist (case-insensitive)
gate_lower=$(printf '%s' "$gate_value" | tr '[:upper:]' '[:lower:]')
if printf '%s' "$gate_lower" | grep -qE '^(tbd|pending|to be determined|todo)$' ||
    printf '%s' "$gate_value" | grep -qE '^<.*>$'; then
    reason="stop-verify-planner-gate: planner stopped with \`**Gate**:\` missing or placeholder in \`## Plan\` of ${log_file}. Per codegen/rules/roles/planner.md Outputs (1), planner MUST declare exact gate command before Stop. Edit step log to set \`**Gate**: <make target>\` inside ## Plan, then return."
    debug_log stop-verify-planner-gate "BLOCK: gate is placeholder ($gate_value)"
    block "$reason"
    exit 0
fi

debug_log stop-verify-planner-gate "allow: gate=$gate_value"
exit 0
