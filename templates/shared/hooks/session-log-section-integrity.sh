#!/bin/bash
# session-log-section-integrity.sh — PreToolUse Edit|Write hook.
#
# When a subagent edits or writes a session log file (codegen/logging/*.md),
# the new_string (Edit) or content (Write) must include
# "## <agent_type> Section" so the session log retains the required section
# header.
#
# Exception: if the section header already exists in the file (follow-up
# edit by the same agent), allow through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log session-log-section-integrity "tool=$TOOL_NAME agent_type=$AGENT_TYPE"

# Only gate Edit, Write, and MultiEdit tools
case "$TOOL_NAME" in
Edit | Write | MultiEdit) ;;
*) exit 0 ;;
esac

# No agent_type means orchestrator — not gated here (orchestrator creates files, not edits)
# Planner writes to ## Plan section (not ## planner Section), so bypass the header gate.
if [ -z "$AGENT_TYPE" ] || [ "$AGENT_TYPE" = "planner" ]; then
    exit 0
fi

# Only gate session log files
if ! printf '%s' "$FILE_PATH" | grep -qE 'codegen/logging/.*\.md$'; then
    exit 0
fi

expected_header="## ${AGENT_TYPE} Section"

# For Edit: if the file exists and already contains the header, allow.
# For Write: if the file already exists and contains the header, allow
# (Write overwrites, but if the writer is preserving the header in content
# that's still fine; we'll check content below).
if [ -f "$FILE_PATH" ]; then
    if grep -qF "$expected_header" "$FILE_PATH" 2>/dev/null; then
        # File already has the header. For Edit, this is the follow-up case.
        # For Write, if the content drops the header, we still want to flag
        # — but Write almost always means a fresh file or a deliberate
        # rewrite, and the header check on content below handles both cases.
        if [ "$TOOL_NAME" = "Edit" ]; then
            exit 0
        fi
    fi
else
    # File doesn't exist yet.
    if [ "$TOOL_NAME" = "Edit" ]; then
        # First write via Edit — allow.
        exit 0
    fi
fi

# Check the relevant payload field for the expected header.
case "$TOOL_NAME" in
Edit)
    payload=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""')
    ;;
Write)
    payload=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // ""')
    ;;
MultiEdit)
    # MultiEdit carries an array of edits; concatenate all new_string values.
    payload=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")')
    ;;
esac

if printf '%s' "$payload" | grep -qF "$expected_header"; then
    exit 0
fi

deny "BLOCKED by session-log-section-integrity: $TOOL_NAME on $FILE_PATH from $AGENT_TYPE must include \"$expected_header\" in the payload."
exit 0
