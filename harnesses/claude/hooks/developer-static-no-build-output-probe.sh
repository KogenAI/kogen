#!/bin/bash
# developer-static-no-build-output-probe.sh — PreToolUse hook: developer-static may not probe build-output dirs (public/, dist/) via Read/Grep/Glob.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Read|Grep|Glob
# surface: user_global
# signal: AGENT_TYPE
# role: developer-static
# harnesses: all
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log developer-static-no-build-output-probe "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# Only guard Read|Grep|Glob tool(s).
case "$TOOL_NAME" in
Read) ;;
Grep) ;;
Glob) ;;
*) exit 0 ;;
esac

# Only apply to role(s): developer-static
case "$AGENT_TYPE" in
developer-static) ;;
*) exit 0 ;;
esac

# Deny: normalise to repo-relative path, then check pattern.
rel=$(repo_relative "$FILE_PATH")
if printf '%s' "$rel" | grep -qE '(^|/)public/|(^|/)dist/'; then
    deny "BLOCKED by developer-static-no-build-output-probe: do not read/grep/glob generated build output (public/, dist/). Inspect SOURCE files; the gate verifies build output automatically.: $FILE_PATH"
    exit 0
fi

exit 0
