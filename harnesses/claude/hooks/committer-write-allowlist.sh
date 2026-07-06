#!/bin/bash
# committer-write-allowlist.sh — PreToolUse hook: committer may only edit canonical session log files (allowlist).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-write-allowlist "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only guard Write|Edit tool(s).
case "$TOOL_NAME" in
Write) ;;
Edit) ;;
*) exit 0 ;;
esac

# Only apply to role(s): committer
case "$AGENT_TYPE" in
committer) ;;
*) exit 0 ;;
esac

# Allowlist: normalise to repo-relative path, then check pattern.
rel=$(repo_relative "$FILE_PATH")
if printf '%s' "$rel" | grep -qE 'codegen/logging/[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$'; then
    exit 0
fi

deny "BLOCKED by committer-write-allowlist: committer may only write to canonical session logs: $FILE_PATH"
exit 0
