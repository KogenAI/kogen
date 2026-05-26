#!/bin/bash
# phoenix-backend-developer-guard.sh — PreToolUse hook for developer-phoenix-backend.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: developer-phoenix-backend
# harnesses: all
#
# Blocks Edit/Write/MultiEdit on frontend-owned paths so the backend developer
# cannot accidentally clobber LiveView templates, HEEx files, JS hooks, or
# other frontend-only files.
#
# Blocked paths (relative to project root):
#   lib/<app>_web/   (any lib/ subtree ending with _web)
#   assets/
#   priv/static/
#   *.heex files
#   *_html.ex files (Phoenix HTML module convention)
#
# All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log phoenix-backend-developer-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only gate the backend developer; all other agents pass through
case "$AGENT_TYPE" in
developer-phoenix-backend) ;;
*)
    exit 0
    ;;
esac

case "$TOOL_NAME" in
Edit | Write | MultiEdit) ;;
*)
    exit 0
    ;;
esac

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# lib/<app>_web/ — frontend LiveView module dir
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)lib/[^/]+_web(/|$)'; then
    deny "BLOCKED by phoenix-backend-developer-guard: $FILE_PATH is under lib/<app>_web/ (frontend). Delegate to developer-phoenix-frontend."
    exit 0
fi

# assets/ — JS hooks, CSS, etc.
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)assets/'; then
    deny "BLOCKED by phoenix-backend-developer-guard: $FILE_PATH is under assets/ (frontend). Delegate to developer-phoenix-frontend."
    exit 0
fi

# priv/static/ — compiled static assets
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)priv/static/'; then
    deny "BLOCKED by phoenix-backend-developer-guard: $FILE_PATH is under priv/static/ (frontend). Delegate to developer-phoenix-frontend."
    exit 0
fi

# *.heex — HEEx template files
if printf '%s' "$FILE_PATH" | grep -qE '\.heex$'; then
    deny "BLOCKED by phoenix-backend-developer-guard: $FILE_PATH is a .heex template (frontend). Delegate to developer-phoenix-frontend."
    exit 0
fi

# *_html.ex — Phoenix HTML module convention
if printf '%s' "$FILE_PATH" | grep -qE '_html\.ex$'; then
    deny "BLOCKED by phoenix-backend-developer-guard: $FILE_PATH is a _html.ex module (frontend). Delegate to developer-phoenix-frontend."
    exit 0
fi

exit 0
