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

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
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
intent_regex='[Ss]hould I|[Nn]eed clarification|[Bb]locked|[Ss]tuck|[Ww]aiting for|[Pp]lease confirm|[Ww]ant me to|[Cc]onfirm before'
if [ "$last_char" = "?" ] || printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE "$intent_regex"; then
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
    next_role_hint="$last_agent just finished — continue the cycle (review → committer, or back to developer if issues found)."
    ;;
*)
    debug_log claude-cycle-guard "skip: last_agent=$last_agent is not mid-cycle"
    exit 0
    ;;
esac

# ScheduleWakeup / async-wait guard — orchestrator is yielding for a background event,
# not abandoning a cycle. Let it stop.
if printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE 'ScheduleWakeup|scheduled.*wakeup|checking back in|seed rebuild|still running|in flight'; then
    debug_log claude-cycle-guard "skip: async-wait signal in last message"
    exit 0
fi

# Verdict guard — only block if the session log contains an actual VE gate verdict.
# Without this, a VE that was blocked by ve-guard or returned INCONCLUSIVE (no actionable
# verdict) still triggers the cycle-guard, causing false-positive blocks.
recent_log=$(session_log_from_transcript)
if [ -n "$recent_log" ] && [ -r "$recent_log" ]; then
    if ! grep -qE 'ALL CLEAR ✅|FAILED ❌|INCONCLUSIVE ⚠️' "$recent_log" 2>/dev/null; then
        debug_log claude-cycle-guard "skip: no VE verdict in session log $recent_log"
        exit 0
    fi
fi

# Locate the current-session log path for the block reason text (transcript-bound).
log_file=$(session_log_from_transcript)
log_pointer="${log_file:-(no session log written yet)}"
debug_log claude-cycle-guard "log_pointer=$log_pointer"

# Increment counter and emit block.
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

reason="Mid-cycle stop detected. Last Agent call in transcript: $last_agent. Per AGENTS.md \"ALWAYS RUN THE FULL CYCLE\", do not return control to the user until committer has run for this step. $next_role_hint Re-read the session log at $log_pointer and continue immediately. (cycle-guard attempt ${count}/2)"

debug_log claude-cycle-guard "BLOCK: last_agent=$last_agent count=$count log=$log_pointer"

block "$reason"
exit 0
