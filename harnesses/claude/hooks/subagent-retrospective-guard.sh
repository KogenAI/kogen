#!/usr/bin/env bash
# subagent-retrospective-guard.sh — SubagentStop hook that asserts the
# returning subagent wrote a ### What I Learned This Step block in the step log.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend|planner-phoenix|planner-static|reviewer-phoenix|reviewer-static
# surface: user_global
# signal: AGENT_TYPE
# role: developer-phoenix-backend|developer-phoenix-frontend|planner-*|reviewer-phoenix|reviewer-static
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks SubagentStop when the returning agent's role event(s) in the active
# JSONL cycle log do not contain a ### What I Learned This Step block with at
# least one non-blank content line — either embedded in a "role" event body,
# or as a dedicated "learned" event (codegen-log append --learned).
#
# Acceptable minimal block:
#   ### What I Learned This Step
#   - nothing notable
#
# Skip when:
#   - AGENT_TYPE not in matcher set
#   - No active step log found in transcript
#   - Agent has no role event in the log yet (defensive — let other guards catch)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/cycle-state.sh"
parse_input

debug_log subagent-retrospective-guard "agent=$AGENT_TYPE"

# Only gate the matched roles.
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | reviewer-phoenix | reviewer-static) ;;
planner*) ;;
*)
    debug_log subagent-retrospective-guard "skip: agent=$AGENT_TYPE not in matcher"
    exit 0
    ;;
esac

# Locate the active step log from the session transcript.
log_file=$(session_log_from_transcript)

if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    debug_log subagent-retrospective-guard "skip: no active step log"
    exit 0
fi

debug_log subagent-retrospective-guard "log=$log_file agent=$AGENT_TYPE"

# Find the agent's role event(s) in the JSONL cycle log. All planner variants
# write under the "planner*" role family (matching the old ## Plan exception);
# other roles match AGENT_TYPE literally.
if [[ "${AGENT_TYPE}" == planner* ]]; then
    role_label="planner"
else
    role_label="${AGENT_TYPE}"
fi

# Check at least one role event exists for this agent.
if [[ "${AGENT_TYPE}" == planner* ]]; then
    role_present=$(jq -e 'select(.ev=="role" and (.role | startswith("planner")))' "$log_file" >/dev/null 2>&1 && echo 1 || echo 0)
else
    role_present=$(jq -e --arg r "$AGENT_TYPE" 'select(.ev=="role" and .role==$r)' "$log_file" >/dev/null 2>&1 && echo 1 || echo 0)
fi
if [ "$role_present" -eq 0 ]; then
    debug_log subagent-retrospective-guard "skip: no role event found for $AGENT_TYPE"
    exit 0
fi

# Concatenate every role-event body for this agent (in call order — a
# re-spawned pass appends another role event, all bodies are scanned) plus
# any dedicated "learned" event bodies (codegen-log append --learned).
if [[ "${AGENT_TYPE}" == planner* ]]; then
    section_body=$(jq -r 'select(.ev=="role" and (.role | startswith("planner")))|.body' "$log_file" 2>/dev/null)
    learned_events=$(jq -r 'select(.ev=="learned" and (.role | startswith("planner")))|.text' "$log_file" 2>/dev/null)
else
    section_body=$(jq -r --arg r "$AGENT_TYPE" 'select(.ev=="role" and .role==$r)|.body' "$log_file" 2>/dev/null)
    learned_events=$(jq -r --arg r "$AGENT_TYPE" 'select(.ev=="learned" and .role==$r)|.text' "$log_file" 2>/dev/null)
fi

debug_log subagent-retrospective-guard "section_body_lines=$(printf '%s' "$section_body" | wc -l | tr -d ' ')"

# Check for ### What I Learned This Step header in the role body, OR a
# dedicated "learned" event (either counts as the retrospective block).
if ! printf '%s' "$section_body" | grep -q '### What I Learned This Step' && [ -z "$learned_events" ]; then
    block "subagent-retrospective-guard: $AGENT_TYPE returned but its role event(s) in the step log are missing the '### What I Learned This Step' block (or a dedicated 'codegen-log append --learned' event). Add this before finishing. Minimal acceptable content: '- nothing notable'. Step log: $log_file"
    exit 0
fi

# A dedicated "learned" event with non-empty text always satisfies the check.
if [ -n "$learned_events" ] && printf '%s' "$learned_events" | grep -qv '^[[:space:]]*$'; then
    debug_log subagent-retrospective-guard "PASS: dedicated learned event present"
    learned_body="$learned_events"
else
    # Check at least one non-blank line follows the header in the role body.
    learned_body=$(printf '%s' "$section_body" | awk '
        /^### What I Learned This Step/{ found=1; next }
        found && /^### /{ exit }
        found { print }
    ')
fi

has_content=0
while IFS= read -r line; do
    # Strip whitespace
    stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$stripped" ]; then
        has_content=1
        break
    fi
done <<EOF
$learned_body
EOF

if [ "$has_content" -eq 0 ]; then
    block "subagent-retrospective-guard: $AGENT_TYPE's '### What I Learned This Step' block (role: ${role_label}) exists but is empty. Add at least one bullet (minimum: '- nothing notable'). Step log: $log_file"
    exit 0
fi

debug_log subagent-retrospective-guard "PASS: retrospective block present and non-empty"

# Stamp REVIEWED only for reviewer roles (not developer/planner which also fire this hook).
case "$AGENT_TYPE" in
reviewer-phoenix | reviewer-static)
    write_cycle_state "REVIEWED" "${log_file:-}" "${SESSION_ID:-unknown}" "" "${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    debug_log subagent-retrospective-guard "stamped REVIEWED for $AGENT_TYPE"
    ;;
esac

exit 0
