#!/bin/bash
# frontend-developer-guard.sh — PreToolUse hook for developer-phoenix-frontend
#
# Blocks Edit/Write/MultiEdit on backend-owned paths so the frontend developer
# cannot accidentally clobber Ecto schemas, migrations, contexts, services,
# workers, or other backend-only files.
#
# Blocked paths (relative to project root):
#   priv/repo/migrations/
#   lib/<app>/           (any lib/ subtree that is NOT lib/<app>_web/)
#   lib/*/contexts/
#   lib/*/services/
#   lib/*/workers/
#
# All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log frontend-developer-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only gate the frontend developer; all other agents pass through
case "$AGENT_TYPE" in
developer-phoenix-frontend) ;;
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

# priv/repo/migrations/ — always backend
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)priv/repo/migrations/'; then
    deny "BLOCKED by frontend-developer-guard: $FILE_PATH is a backend migration file. Delegate to developer-phoenix-backend."
    exit 0
fi

# lib/*/contexts/, lib/*/services/, lib/*/workers/ — backend subtrees
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)lib/[^/]+/(contexts|services|workers)/'; then
    deny "BLOCKED by frontend-developer-guard: $FILE_PATH is a backend context/service/worker path. Delegate to developer-phoenix-backend."
    exit 0
fi

# lib/<app>/ where the segment does NOT end with _web — backend app dir
# Match: /lib/<word>/ where <word> does not end with _web
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)lib/[^/]+_web(/|$)'; then
    # It's a _web path — allow
    exit 0
fi
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)lib/[^/]+/'; then
    deny "BLOCKED by frontend-developer-guard: $FILE_PATH is under lib/<app>/ (backend). Delegate to developer-phoenix-backend."
    exit 0
fi

exit 0
