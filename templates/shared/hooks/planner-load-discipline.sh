#!/bin/bash
# planner-load-discipline.sh — PreToolUse Read hook scoped to planner.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Read
# surface: user_global
# signal: AGENT_TYPE
# role: planner
#
# Blocks the planner from loading implementer-only rule files that are
# already baked into the implementer subagent prompts. Loading them
# wastes tokens and risks the planner over-specifying implementation.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log planner-load-discipline "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate planner
if [ "$AGENT_TYPE" != "planner" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Read" ]; then
    exit 0
fi

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Get basename of the file
basename="${FILE_PATH##*/}"

# Check against forbidden implementer rule files
forbidden_list="testing.md testing-liveview.md developer.md reviewer.md committer.md"
for forbidden in $forbidden_list; do
    if [ "$basename" = "$forbidden" ]; then
        deny "BLOCKED by planner-load-discipline: planner must not load implementer rules ($basename). These are baked into the implementer subagent prompts already."
        exit 0
    fi
done

exit 0
