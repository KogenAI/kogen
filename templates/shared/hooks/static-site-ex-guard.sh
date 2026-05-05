#!/bin/bash
# static-site-ex-guard.sh — PreToolUse hook for static-site-developer
#
# Blocks Write and Edit tool calls targeting Elixir/HEEX files when the active
# agent is "static-site-developer". All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log static-site-ex-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only gate static-site-developer; allow all other agents unconditionally
if [ "$AGENT_TYPE" != "static-site-developer" ]; then
    exit 0
fi

# Block Write or Edit calls targeting Elixir/HEEX files
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    if printf '%s' "$FILE_PATH" | grep -qE '\.(ex|exs|heex)$'; then
        deny "BLOCKED by static-site-ex-guard: static-site-developer cannot edit Elixir/HEEX files ($FILE_PATH). Re-delegate to phoenix-developer."
        exit 0
    fi
fi

exit 0
