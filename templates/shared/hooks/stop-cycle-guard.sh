#!/usr/bin/env bash
# stop-cycle-guard.sh — Stop hook that prevents the orchestrator from ending
# its turn mid-delegation-cycle.

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

# Locate most recently modified session log under <project>/codegen/logging/.
logging_dir="$project_dir/codegen/logging"
if [ ! -d "$logging_dir" ]; then
    debug_log claude-cycle-guard "skip: no logging dir at $logging_dir"
    exit 0
fi

# Find the most recent .md file modified within the last 60 minutes.
log_file=$(find "$logging_dir" -maxdepth 1 -type f -name '*.md' -mmin -60 2>/dev/null |
    xargs -I{} stat -f '%m %N' {} 2>/dev/null |
    sort -rn |
    head -n 1 |
    awk '{$1=""; sub(/^ /, ""); print}')

if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    debug_log claude-cycle-guard "skip: no recent log file"
    exit 0
fi

# Extract the `## Delegation Timeline` table.
timeline=$(awk '
    /^## Delegation Timeline/ { in_table = 1; next }
    in_table && /^## / { in_table = 0 }
    in_table && /^\|/ { print }
' "$log_file")

if [ -z "$timeline" ]; then
    debug_log claude-cycle-guard "skip: no delegation timeline section"
    exit 0
fi

# Skip header rows (column 2 == "Time" or starts with `---`). Read the agent
# column (column 3 between the second and third `|`).
last_agent=$(printf '%s\n' "$timeline" |
    awk -F'|' '
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
    debug_log claude-cycle-guard "skip: no agent rows in timeline"
    exit 0
fi

case "$last_agent" in
phoenix-developer | static-site-developer | data-layer-developer | verification-engineer | code-reviewer)
    next_role_hint="$last_agent just finished — continue the cycle (VE → CR → committer, or back to developer if issues found)."
    ;;
*)
    debug_log claude-cycle-guard "skip: last_agent=$last_agent is not mid-cycle"
    exit 0
    ;;
esac

# Increment counter and emit block.
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

reason="Mid-cycle stop detected. Last delegation timeline row: $last_agent. Per AGENTS.md \"ALWAYS RUN THE FULL CYCLE\", do not return control to the user until committer has run for this step. $next_role_hint Re-read the session log at $log_file and continue immediately. (cycle-guard attempt ${count}/2)"

debug_log claude-cycle-guard "BLOCK: last_agent=$last_agent count=$count log=$log_file"

block "$reason"
exit 0
