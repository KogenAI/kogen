#!/usr/bin/env bash
# stop-cycle-guard.sh — Stop hook that prevents the orchestrator from ending
# its turn mid-delegation-cycle.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: none
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-control.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-result.sh"
parse_input

session_id="${SESSION_ID:-unknown}"
project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
counter_file="/tmp/claude-cycle-guard-${session_id}.count"

debug_log claude-cycle-guard "session=$session_id"

# Loop guard — already fired this stop.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log claude-cycle-guard "skip: stop_hook_active"
    exit 0
fi

# Retry cap.
count=0
if [ -r "$counter_file" ]; then
    count=$(cat "$counter_file" 2>/dev/null || echo 0)
fi
case "$count" in
'' | *[!0-9]*) count=0 ;;
esac
if [ "$count" -ge 2 ]; then
    debug_log claude-cycle-guard "skip: retry-cap count=$count"
    rm -f "$counter_file"
    exit 0
fi

# Intent guard: orchestrator is asking the user something — let it stop.
trimmed=$(printf '%s' "$LAST_ASSISTANT_MESSAGE" | sed -E 's/[[:space:]]+$//')
last_char="${trimmed: -1}"
if [ "$last_char" = "?" ]; then
    debug_log claude-cycle-guard "skip: intent — last_char=$last_char"
    exit 0
fi

# Cycle state from transcript — session-bound, authoritative.
# Replaces the log-file recency heuristic that matched stale prior-session logs.
debug_log claude-cycle-guard "transcript_path=$TRANSCRIPT_PATH"
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log claude-cycle-guard "skip: no transcript path"
    exit 0
fi

last_agent=$(jq -r '
    select(.message.content)
    | (.message.content[]?
        | select(.type == "tool_use" and .name == "Agent")
        | .input.subagent_type)
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)

debug_log claude-cycle-guard "last_agent=$last_agent"

if [ -z "$last_agent" ]; then
    debug_log claude-cycle-guard "skip: no Agent calls in transcript"
    exit 0
fi

case "$last_agent" in
developer-phoenix-backend | developer-phoenix-frontend | developer-html | developer-hugo | developer-vite | reviewer-phoenix | reviewer-static)
    next_role_hint="$last_agent just finished — continue the cycle (review → context-curator → committer, or back to developer if issues found)."
    ;;
context-curator)
    next_role_hint="context-curator just finished — continue to committer."
    ;;
*)
    debug_log claude-cycle-guard "skip: last_agent=$last_agent is not mid-cycle"
    exit 0
    ;;
esac

# ── In-flight gate check: block if a gate is still running ─────────────────
# Must run BEFORE async-wait guard and verdict guard to ensure we block when
# a gate PID is genuinely alive. Only allow the stop if no flag is in flight.
in_flight_summary=$(gate_control_status "$project_dir" 2>/dev/null || true)
if [ -n "$in_flight_summary" ]; then
    # gate_control_status exits 0 and prints summary only when in-flight
    in_flight_pid=$(printf '%s' "$in_flight_summary" | grep -oE 'pid=[0-9]+' | head -n 1 | cut -d= -f2-)
    in_flight_gate=$(printf '%s' "$in_flight_summary" | grep -oE 'gate=[^[:space:]]+' | head -n 1 | cut -d= -f2-)
    debug_log claude-cycle-guard "BLOCK: gate in-flight pid=$in_flight_pid gate=$in_flight_gate"
    block "An in-flight gate (PID ${in_flight_pid:-unknown}, gate '${in_flight_gate:-unknown}') has not produced a verdict. You MUST NOT end your turn while a gate runs. Wait for the gate to complete and write its verdict to the step log before stopping."
    exit 0
fi

# ── ScheduleWakeup / async-wait guard ──────────────────────────────────────
# Only allow async-wait escape when NO flag is in flight (enforced above).
# Orchestrator is yielding for a background event, not abandoning a cycle.
# Only allow async-wait escape when a ScheduleWakeup tool_use appears in the
# transcript — prose alone ("still running", "in flight") is insufficient and
# can be spoofed. Require a real tool-call record.
has_schedule_wakeup=$(jq -r '
    select(.message.content)
    | (.message.content[]?
        | select(.type == "tool_use" and .name == "ScheduleWakeup")
        | .name)
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)

if [ -n "$has_schedule_wakeup" ]; then
    debug_log claude-cycle-guard "skip: ScheduleWakeup tool_use in transcript"
    exit 0
fi

# Verdict guard — behaviour differs by role:
#
#   developer-* + no emoji verdict + no gate-result.json  → BLOCK (VE never ran)
#   developer-* + gate-result.json verdict=inconclusive   → allow (explicit recorded state)
#   reviewer-* + no emoji verdict                         → allow (VE blocked/inconclusive is ok)
#   all roles   + gate-result.json non-clear              → allow (gate ran, result recorded)
#
# Rationale: "developer finished + no verdict + no gate-result" is exactly the
# historical #1 bail — gate never executed at all. Distinguish from the
# legitimate case where VE ran but produced INCONCLUSIVE (gate-result.json present).
recent_log=$(session_log_from_transcript)
if [ -n "$recent_log" ] && [ -r "$recent_log" ]; then
    if ! grep -qE 'ALL CLEAR ✅|FAILED ❌|INCONCLUSIVE ⚠️' "$recent_log" 2>/dev/null; then
        # No emoji verdict in log — check gate-result.json as secondary source
        stored_verdict=$(gate_result_verdict "$project_dir")
        case "$last_agent" in
        developer-phoenix-backend | developer-phoenix-frontend | developer-html | developer-hugo | developer-vite)
            if [ -z "$stored_verdict" ]; then
                # Developer ran but VE never produced any verdict — BLOCK.
                debug_log claude-cycle-guard "BLOCK: developer ran but gate never produced a verdict (gate-result absent)"
                count=$((count + 1))
                printf '%s' "$count" >"$counter_file"
                log_file=$(session_log_from_transcript)
                log_pointer="${log_file:-(no session log written yet)}"
                block "Developer finished but the gate never produced a verdict (no emoji in session log, no gate-result.json). VE never ran. You MUST NOT stop here — continue the cycle: re-read $log_pointer and run the gate before handing off to reviewer."
                exit 0
            elif [ "$stored_verdict" = "inconclusive" ]; then
                debug_log claude-cycle-guard "skip: developer ran, gate-result=inconclusive (explicit recorded state)"
                exit 0
            fi
            # gate-result.json says failed/clear but log lacks emoji — log may be out of sync; fall through to block
            debug_log claude-cycle-guard "gate-result.json verdict=$stored_verdict but log has no emoji marker"
            ;;
        *)
            # reviewer-* or context-curator: no verdict is ok — VE may have been blocked
            if [ -z "$stored_verdict" ] || [ "$stored_verdict" = "inconclusive" ]; then
                debug_log claude-cycle-guard "skip: no VE verdict in session log $recent_log (gate-result: ${stored_verdict:-absent})"
                exit 0
            fi
            debug_log claude-cycle-guard "gate-result.json verdict=$stored_verdict but log has no emoji marker"
            ;;
        esac
    fi
    # When gate-result.json says non-clear, don't treat stale log ALL CLEAR as satisfying
    stored_verdict=$(gate_result_verdict "$project_dir")
    if [ -n "$stored_verdict" ] && [ "$stored_verdict" != "clear" ]; then
        debug_log claude-cycle-guard "skip: gate-result.json verdict=$stored_verdict (non-clear)"
        exit 0
    fi
fi

# Locate the current-session log path for the block reason text (transcript-bound).
log_file=$(session_log_from_transcript)
log_pointer="${log_file:-(no session log written yet)}"
debug_log claude-cycle-guard "log_pointer=$log_pointer"

# Gate-clear + dirty-tree: block if gate passed but working tree is dirty.
dt_verdict=$(gate_result_verdict "$project_dir")
if [ "$dt_verdict" = "clear" ] && [ -n "$(git -C "$project_dir" status --porcelain 2>/dev/null)" ]; then
    debug_log "stop-cycle-guard: gate=clear but tree dirty — blocking stop"
    block "Gate passed but the working tree is dirty (uncommitted changes). You MUST NOT end your turn with an uncommitted tree — delegate to committer to commit this step's output before stopping."
    exit 0
fi

# Increment counter and emit block.
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

reason="Mid-cycle stop detected. Last Agent call in transcript: $last_agent. Per AGENTS.md \"ALWAYS RUN THE FULL CYCLE\", do not return control to the user until committer has run for this step. $next_role_hint Re-read the session log at $log_pointer and continue immediately. (cycle-guard attempt ${count}/2)"

debug_log claude-cycle-guard "BLOCK: last_agent=$last_agent count=$count log=$log_pointer"

block "$reason"
exit 0
