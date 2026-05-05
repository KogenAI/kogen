#!/usr/bin/env bash
# stop-cycle-guard.sh — Stop hook that prevents the orchestrator from ending
# its turn mid-delegation-cycle.
#
# Failure mode this addresses:
#   The orchestrator's contract is planner → developer → VE → CR → committer.
#   Sometimes the model returns control to the user after a developer or VE
#   subagent finishes, instead of immediately delegating to the next role.
#   The user only notices when they next look at the screen — wasting hours.
#
# Detection: read the most recently modified session log under
# `<cwd>/codegen/logging/`. Look at the `## Delegation Timeline` table. If the
# last delegation row is for a developer or verification-engineer (i.e., the
# cycle is mid-flight) AND no committer row appears AFTER it, this is a
# mid-cycle stop. Block it.
#
# Safety guards (any one prevents blocking — chosen conservatively because a
# false-positive blocks the session from ending until the retry cap):
#   - stop_hook_active=true (loop guard, mandatory)
#   - retry counter ≥ 2 (prevents infinite re-trigger)
#   - last assistant message ends with `?`, or contains "should I", "need
#     clarification", "blocked", "stuck", "waiting for" — orchestrator is
#     intentionally asking the user something
#   - no session log found, or the session log is older than 60 minutes
#   - no `## Delegation Timeline` section in the log
#   - last timeline row is committer (cycle complete) or planner (cycle just
#     started, no developer to chase yet)
#
# Protocol: print {"decision":"block","reason":"..."} on stdout, exit 0 to
# inject a synthetic user turn that nudges the orchestrator to continue.

set -u

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
last_assistant_message=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""')
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

project_dir="${hook_cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
counter_file="/tmp/claude-cycle-guard-${session_id}.count"
debug_log="/tmp/claude-cycle-guard.log"

log_debug() {
    if [ -n "${CLAUDE_CYCLE_GUARD_DEBUG:-}" ]; then
        printf '%s session=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session_id" "$1" \
            >>"$debug_log" 2>/dev/null || true
    fi
}

# Loop guard — already fired this stop.
if [ "$stop_hook_active" = "true" ]; then
    log_debug "skip: stop_hook_active"
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
    log_debug "skip: retry-cap count=$count"
    rm -f "$counter_file"
    exit 0
fi

# Intent guard: orchestrator is asking the user something — let it stop.
trimmed=$(printf '%s' "$last_assistant_message" | sed -E 's/[[:space:]]+$//')
last_char="${trimmed: -1}"
intent_regex='[Ss]hould I|[Nn]eed clarification|[Bb]locked|[Ss]tuck|[Ww]aiting for|[Pp]lease confirm|[Ww]ant me to|[Cc]onfirm before'
if [ "$last_char" = "?" ] || printf '%s' "$last_assistant_message" | grep -qE "$intent_regex"; then
    log_debug "skip: intent — last_char=$last_char"
    exit 0
fi

# Locate most recently modified session log under <project>/codegen/logging/.
logging_dir="$project_dir/codegen/logging"
if [ ! -d "$logging_dir" ]; then
    log_debug "skip: no logging dir at $logging_dir"
    exit 0
fi

# Find the most recent .md file modified within the last 60 minutes.
log_file=$(find "$logging_dir" -maxdepth 1 -type f -name '*.md' -mmin -60 2>/dev/null |
    xargs -I{} stat -f '%m %N' {} 2>/dev/null |
    sort -rn |
    head -n 1 |
    awk '{$1=""; sub(/^ /, ""); print}')

if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    log_debug "skip: no recent log file"
    exit 0
fi

# Extract the `## Delegation Timeline` table. The table starts at the heading
# line and ends at the next `## ` heading or EOF. We then look at table rows
# only (lines starting with `|` and containing an agent name in column 3).
timeline=$(awk '
    /^## Delegation Timeline/ { in_table = 1; next }
    in_table && /^## / { in_table = 0 }
    in_table && /^\|/ { print }
' "$log_file")

if [ -z "$timeline" ]; then
    log_debug "skip: no delegation timeline section"
    exit 0
fi

# Skip header rows (column 2 == "Time" or starts with `---`). Read the agent
# column (column 3 between the second and third `|`).
last_agent=$(printf '%s\n' "$timeline" |
    awk -F'|' '
        # Skip header (col 2 trimmed equals "Time") and separator rows.
        {
            t = $2
            gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (t == "Time" || t ~ /^-+$/ || t == "") next
            agent = $3
            gsub(/^[ \t]+|[ \t]+$/, "", agent)
            if (agent != "") last = agent
        }
        END { print last }
    ')

if [ -z "$last_agent" ]; then
    log_debug "skip: no agent rows in timeline"
    exit 0
fi

# Mid-cycle agents: a developer or VE returning means a committer must follow.
# We treat code-reviewer the same way — if CR ran and approved, committer is
# next; if CR found issues, the next role is the developer (mid-cycle).
case "$last_agent" in
phoenix-developer | static-site-developer | data-layer-developer | verification-engineer | code-reviewer)
    next_role_hint="$last_agent just finished — continue the cycle (VE → CR → committer, or back to developer if issues found)."
    ;;
*)
    log_debug "skip: last_agent=$last_agent is not mid-cycle"
    exit 0
    ;;
esac

# Increment counter and emit block.
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

reason="Mid-cycle stop detected. Last delegation timeline row: $last_agent. Per AGENTS.md \"ALWAYS RUN THE FULL CYCLE\", do not return control to the user until committer has run for this step. $next_role_hint Re-read the session log at $log_file and continue immediately. (cycle-guard attempt ${count}/2)"

log_debug "BLOCK: last_agent=$last_agent count=$count log=$log_file"

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
exit 0
