#!/usr/bin/env bash
# subagent-retrospective-guard.sh — SubagentStop hook that asserts the
# returning subagent wrote a ### What I Learned This Step block in the step log.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend|planner-phoenix|reviewer-phoenix
# surface: user_global
# signal: AGENT_TYPE
# role: developer-phoenix-backend|developer-phoenix-frontend|planner-phoenix|reviewer-phoenix
# harnesses: all
#
# Blocks SubagentStop when the returning agent's ## <role> Section in the
# active step log does not contain a ### What I Learned This Step header
# followed by at least one non-blank content line.
#
# Acceptable minimal block:
#   ### What I Learned This Step
#   - nothing notable
#
# Skip when:
#   - AGENT_TYPE not in matcher set
#   - No active step log found in transcript
#   - Agent's ## <role> Section not found in log (defensive — let other guards catch)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log subagent-retrospective-guard "agent=$AGENT_TYPE"

# Only gate the matched roles.
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | planner-phoenix | reviewer-phoenix) ;;
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

# Find the agent's ## <role> Section header in the log.
# Extract lines from that header to the next ^## header (or EOF).
# planner-phoenix writes its body under ## Plan (not ## planner-phoenix Section).
if [[ "${AGENT_TYPE}" == "planner-phoenix" ]]; then
    section_header="## Plan"
else
    section_header="## ${AGENT_TYPE} Section"
fi

# Check the section header exists.
if ! grep -qF "$section_header" "$log_file" 2>/dev/null; then
    debug_log subagent-retrospective-guard "skip: no section header found for $AGENT_TYPE"
    exit 0
fi

# Extract the section body: from the section header to the next ^## (exclusive) or EOF.
# We use awk for this — portable, no temp files needed.
section_body=$(awk "
    /^## /{
        if (in_section) { exit }
    }
    /^${section_header//\//\\/}/{
        in_section = 1
        next
    }
    in_section { print }
" "$log_file" 2>/dev/null)

debug_log subagent-retrospective-guard "section_body_lines=$(printf '%s' "$section_body" | wc -l | tr -d ' ')"

# Check for ### What I Learned This Step header in the section.
if ! printf '%s' "$section_body" | grep -q '### What I Learned This Step'; then
    block "subagent-retrospective-guard: $AGENT_TYPE returned but its ${section_header} in the step log is missing the '### What I Learned This Step' block. Add this block to your section before finishing. Minimal acceptable content: '- nothing notable'. Step log: $log_file"
    exit 0
fi

# Check at least one non-blank line follows the header.
learned_body=$(printf '%s' "$section_body" | awk '
    /^### What I Learned This Step/{ found=1; next }
    found && /^### /{ exit }
    found { print }
')

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
    block "subagent-retrospective-guard: $AGENT_TYPE's '### What I Learned This Step' block in ${section_header} exists but is empty. Add at least one bullet (minimum: '- nothing notable'). Step log: $log_file"
    exit 0
fi

debug_log subagent-retrospective-guard "PASS: retrospective block present and non-empty"
exit 0
