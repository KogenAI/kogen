#!/usr/bin/env bash
# stop-spin-guard.sh — SubagentStop hook that detects intra-developer spin:
# N consecutive same-role developer SubagentStop events within a session.
# Forces escalation to planner at threshold to break prompt-governed retry loops.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend|developer-static
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*
# harnesses: claude_code
# rationale: developer-* SubagentStop spin circuit-breaker; no Pi equivalent (Pi Stop-control is observe-only, cannot block) — NOT-YET-PORTED.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Spin definition: ≥3 consecutive same-role developer Agent spawns in the
# transcript since the last non-developer Agent call (reviewer/curator/committer
# /planner resets the run). Consecutive = same AGENT_TYPE with no intervening
# non-developer Agent call.
#
# Cap: after 2 blocks the counter file is cleared to prevent wedging a
# genuinely stuck session. Mirrors the cap=2 pattern in stop-cycle-guard.sh.
#
# Counter file: /tmp/claude-spin-<session>.count — tracks block count only
# (not spawn count, which is derived from the transcript each call).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Only act on developer-* variants.
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | developer-static) ;;
*)
    debug_log stop-spin-guard "skip: agent_type=$AGENT_TYPE is not developer-*"
    exit 0
    ;;
esac

# Loop guard.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log stop-spin-guard "skip: stop_hook_active"
    exit 0
fi

session_id="${SESSION_ID:-unknown}"
block_counter_file="/tmp/claude-spin-${session_id}.count"

debug_log stop-spin-guard "session=$session_id agent=$AGENT_TYPE"

# Resolve step log early for per-step counter scoping.
step_log=$(session_log_from_transcript)

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
if [ -n "$step_log" ] && [ "$step_log" != "$prev_step" ]; then
    block_count=0
fi
if [ "$block_count" -ge 2 ]; then
    debug_log stop-spin-guard "skip: block cap=$block_count reached — releasing"
    rm -f "$block_counter_file"
    exit 0
fi

# Require transcript to derive consecutive-spawn count.
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log stop-spin-guard "skip: no transcript path"
    exit 0
fi

# Count consecutive same-developer-role Agent spawns from transcript.
# Strategy: extract subagent_type from all Agent tool_use entries in order,
# then count the trailing run of the current AGENT_TYPE using awk.
consecutive_count=$(jq -r '
    select(.message.content)
    | (.message.content[]?
        | select(.type == "tool_use" and .name == "Agent")
        | .input.subagent_type)
' "$TRANSCRIPT_PATH" 2>/dev/null | awk -v role="$AGENT_TYPE" '
BEGIN { run = 0 }
{
    if ($0 == role) {
        run++
    } else {
        run = 0
    }
}
END { print run }
')

# Sanitise — must be a non-negative integer.
case "$consecutive_count" in
'' | *[!0-9]*) consecutive_count=0 ;;
esac

debug_log stop-spin-guard "consecutive_count=$consecutive_count agent=$AGENT_TYPE"

if [ "$consecutive_count" -lt 3 ]; then
    debug_log stop-spin-guard "allow: consecutive_count=$consecutive_count < 3"
    exit 0
fi

# Consecutive same-developer spin detected — BLOCK and increment block counter.
block_count=$((block_count + 1))
printf '%s\n%s' "${step_log:-}" "$block_count" >"$block_counter_file"

debug_log stop-spin-guard "BLOCK: consecutive_count=$consecutive_count block_count=$block_count agent=$AGENT_TYPE"

block "Spin detected: $AGENT_TYPE has been spawned $consecutive_count consecutive times without a reviewer/curator/committer interleaved. This is a stuck-loop — do NOT spawn the same developer again. Escalate to planner-phoenix immediately: run \`claude --agent planner-phoenix --print --output-format text \"STUCK-ESCALATION: <problem> + <what was tried> + <current failure>. One recommendation.\"\` and apply the planner's recommendation before re-spawning the developer. (spin-guard block ${block_count}/2)"
exit 0
