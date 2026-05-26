#!/bin/bash
# static-site-ex-guard.sh — PreToolUse hook for developer-html | developer-hugo | developer-vite
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit
# surface: user_global
# signal: AGENT_TYPE
# role: developer-html|developer-hugo|developer-vite
# harnesses: all
#
# Blocks Write and Edit tool calls targeting Elixir/HEEX files when the active
# agent is "developer-html | developer-hugo | developer-vite". All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log static-site-ex-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only gate static-site developers; allow all other agents unconditionally
case "$AGENT_TYPE" in
developer-html | developer-hugo | developer-vite) ;;
*) exit 0 ;;
esac

# Block Write or Edit calls targeting Elixir/HEEX files
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
    if printf '%s' "$FILE_PATH" | grep -qE '\.(ex|exs|heex)$'; then
        deny "BLOCKED by static-site-ex-guard: static-site developer cannot edit Elixir/HEEX files ($FILE_PATH). Re-delegate to developer-phoenix-backend / developer-phoenix-frontend."
        exit 0
    fi
fi

exit 0
