#!/bin/bash
# single-cycle-agent-in-flight.sh — PreToolUse Agent hook (fail-closed).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: claude_code
# rationale: Claude Code Task-tool in-flight tracking has no Pi equivalent; Pi lacks a comparable Agent-spawn PreToolUse hook point for this check
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Enforces the build-cycle invariant "one cycle agent in flight at a time".
# Denies spawning a cycle-family subagent when the transcript shows an
# already-in-flight Agent spawn (an Agent tool_use with no matching
# tool_result). Defends against Claude Code auto-backgrounding Agent() calls
# and the orchestrator spawning a second cycle agent → two-writers-one-tree.
#
# Logic:
#   TOOL_NAME != "Agent"                    → exit 0 (not our concern)
#   resolve_role in {debug,shape,ops}       → exit 0 (investigative bypass)
#   subagent_type not cycle-family           → exit 0 (Explore etc. not guarded)
#   transcript unreadable                    → exit 0 (fail-open: state unknown)
#   in-flight Agent spawn present            → DENY (fail-closed)
#   else                                     → exit 0 (allow)
#
# In-flight = an Agent tool_use whose id has no matching tool_result
# tool_use_id anywhere in the transcript. A completed (synchronous) subagent
# always has its tool_result recorded before the next spawn.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

_role=$(resolve_role)
debug_log single-cycle-agent-in-flight "role=$_role"
if ! is_build_mode; then
    debug_log single-cycle-agent-in-flight "investigative bypass (role=$_role)"
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
debug_log single-cycle-agent-in-flight "subagent_type=$subagent_type"

# Cycle-family roles only. Non-cycle types (Explore, Plan, general-purpose,
# statusline-setup, empty) are not part of the build cycle → not guarded here.
case "$subagent_type" in
planner-phoenix | planner-static | \
    developer-phoenix-backend | developer-phoenix-frontend | developer-static | \
    reviewer-phoenix | reviewer-static | \
    context-curator | committer)
    : # cycle-family — continue to in-flight check
    ;;
*)
    debug_log single-cycle-agent-in-flight "non-cycle type — allow"
    exit 0
    ;;
esac

# Transcript readable guard — fail-open when unreadable (state unknown).
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log single-cycle-agent-in-flight "fail-open: transcript unreadable"
    exit 0
fi

# Collect all Agent spawn tool_use ids.
agent_ids=$(jq -r '
    select(.message.content)
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Agent")
    | .id
' "$TRANSCRIPT_PATH" 2>/dev/null | grep -v '^$' | sort -u)

# Collect all tool_result tool_use_ids (completions).
result_ids=$(jq -r '
    select(.message.content)
    | .message.content[]?
    | select(.type == "tool_result")
    | .tool_use_id
' "$TRANSCRIPT_PATH" 2>/dev/null | grep -v '^$' | sort -u)

debug_log single-cycle-agent-in-flight "agent_ids=[$agent_ids] result_ids=[$result_ids]"

# In-flight = Agent ids with no matching completion. comm -23 = lines only in
# the first (sorted) set. If non-empty, a cycle agent is already in flight.
in_flight=$(comm -23 <(printf '%s\n' "$agent_ids") <(printf '%s\n' "$result_ids") | grep -v '^$')

if [ -n "$in_flight" ]; then
    debug_log single-cycle-agent-in-flight "DENY: in-flight agent id(s): $in_flight"

    bc_sid="${SESSION_ID:-unknown}"
    bc_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bc_mtime=$(stat -c '%Y' "$TRANSCRIPT_PATH" 2>/dev/null || stat -f '%m' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
    bc_agent_ids=$(printf '%s' "$agent_ids" | tr '\n' ' ')
    bc_result_ids=$(printf '%s' "$result_ids" | tr '\n' ' ')
    bc_in_flight=$(printf '%s' "$in_flight" | tr '\n' ' ')
    bc_last_types=$(tail -n 5 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '.type // "?"' 2>/dev/null | tr '\n' ',')
    bc=$(jq -n \
        --arg ts "$bc_ts" \
        --arg guard "single-cycle-agent-in-flight" \
        --arg session_id "$bc_sid" \
        --arg transcript_path "$TRANSCRIPT_PATH" \
        --arg transcript_mtime "$bc_mtime" \
        --arg agent_ids "$bc_agent_ids" \
        --arg result_ids "$bc_result_ids" \
        --arg in_flight "$bc_in_flight" \
        --arg last_line_types "$bc_last_types" \
        '{ts: $ts, guard: $guard, session_id: $session_id, transcript_path: $transcript_path,
          transcript_mtime: ($transcript_mtime | tonumber), agent_ids: $agent_ids,
          result_ids: $result_ids, in_flight: $in_flight, last_line_types: $last_line_types}' 2>/dev/null)
    guard_breadcrumb "$bc_sid" "$bc"

    deny "BLOCKED: a cycle agent is already in flight (Agent spawn with no completion in the transcript). The build cycle runs ONE cycle agent at a time — spawning '${subagent_type}' now would collide two writers on one tree. Wait for the in-flight agent to finish (its result will appear in the transcript), then spawn. Do not spawn a status-check or second cycle agent while one is running. A diagnostic breadcrumb was recorded at codegen/logging/.guard-diagnostics/${bc_sid}.jsonl; if this recurs, attach it to the guard-false-positive pitch."
    exit 0
fi

debug_log single-cycle-agent-in-flight "allow: no in-flight cycle agent"
exit 0
