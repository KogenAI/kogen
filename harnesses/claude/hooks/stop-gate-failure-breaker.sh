#!/usr/bin/env bash
# stop-gate-failure-breaker.sh — SubagentStop circuit-breaker: blocks and forces
# escalation to planner-phoenix once the dev-gate has logged ≥3 FAILED ❌ verdicts
# in the active session log. Turns the advisory "ROOT-CAUSE: route to planner"
# suffix written by phoenix-dev-gate.sh into an enforced stop.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend|developer-static
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*
# harnesses: all
# rationale: Blocks and forces planner escalation when the dev-gate has logged ≥3 FAILED verdicts in the session — turns the advisory "route to planner" suffix into an enforced circuit-breaker.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Signal: session-log FAILED ❌ count (monotonic within a session, written by
# phoenix-dev-gate.sh each time it fires with a failed verdict). Cross-checked
# against gate_result_verdict to avoid blocking on stale/inconclusive runs.
#
# Cap: after 2 blocks the counter file is cleared to prevent wedging a genuinely
# stuck session. Mirrors the cap=2 pattern in stop-spin-guard.sh and
# stop-cycle-guard.sh.
#
# Counter file: /tmp/claude-gate-breaker-<session>.count — tracks block count only
# (not failure count, which is derived from the session log each call).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/lib/gate-result.sh"
parse_input

# Only act on developer-* variants.
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | developer-static) ;;
*)
    debug_log stop-gate-failure-breaker "skip: agent_type=$AGENT_TYPE is not developer-*"
    exit 0
    ;;
esac

# Loop guard.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log stop-gate-failure-breaker "skip: stop_hook_active"
    exit 0
fi

session_id="${SESSION_ID:-unknown}"
block_counter_file="/tmp/claude-gate-breaker-${session_id}.count"
project_dir="$CWD"
[ -z "$project_dir" ] && project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

debug_log stop-gate-failure-breaker "session=$session_id agent=$AGENT_TYPE project_dir=$project_dir"

# Require a discoverable session log (needed for step-scoped counter and failure count).
log_file=$(session_log_from_transcript)
if [ -z "$log_file" ]; then
    debug_log stop-gate-failure-breaker "skip: no session log in transcript"
    exit 0
fi

# Block count cap=2 (two-line per-step counter: line1=step_log, line2=count).
prev_step=""
block_count=0
if [ -r "$block_counter_file" ]; then
    prev_step=$(sed -n '1p' "$block_counter_file" 2>/dev/null || printf '')
    block_count=$(sed -n '2p' "$block_counter_file" 2>/dev/null || printf '0')
fi
case "$block_count" in
'' | *[!0-9]*) block_count=0 ;;
esac
# Forward progress to a new step resets the block budget.
if [ -n "$log_file" ] && [ "$log_file" != "$prev_step" ]; then
    block_count=0
fi
if [ "$block_count" -ge 2 ]; then
    debug_log stop-gate-failure-breaker "skip: block cap=$block_count reached — releasing"
    rm -f "$block_counter_file"
    exit 0
fi

# Count FAILED ❌ verdicts in the session log.
failed_count=$(grep -c 'FAILED ❌' "$log_file" 2>/dev/null || true)
case "$failed_count" in
'' | *[!0-9]*) failed_count=0 ;;
esac

# Cross-check the latest gate verdict — only block on confirmed failure trajectory.
verdict=$(gate_result_verdict "$project_dir")

debug_log stop-gate-failure-breaker "failed_count=$failed_count verdict=$verdict block_count=$block_count"

if [ "$failed_count" -lt 3 ] || [ "$verdict" != "failed" ]; then
    debug_log stop-gate-failure-breaker "allow: failed_count=$failed_count verdict=$verdict"
    exit 0
fi

# Gate has failed ≥3 times with no progress — BLOCK and increment block counter.
block_count=$((block_count + 1))
printf '%s\n%s' "$log_file" "$block_count" >"$block_counter_file"

debug_log stop-gate-failure-breaker "BLOCK: failed_count=$failed_count verdict=$verdict block_count=$block_count agent=$AGENT_TYPE"

block "BLOCKED by stop-gate-failure-breaker: dev-gate has failed $failed_count times with no progress. Do NOT re-spawn the developer. Escalate to planner-phoenix with the failure context and gate log. (gate-breaker block ${block_count}/2)"
exit 0
