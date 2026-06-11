#!/bin/bash
# committer-bash-allowlist.sh — PreToolUse hook: committer may only run git commands and safe shell utilities (allowlist).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
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

debug_log committer-bash-allowlist "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only apply to role(s): committer
case "$AGENT_TYPE" in
committer) ;;
*) exit 0 ;;
esac

# Allowlist: allow matching commands; deny everything else.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*(cd[[:space:]]+\S+[[:space:]]+&&[[:space:]]+)?(git[[:space:]]+(-C[[:space:]]+\S+[[:space:]]+)?(diff|status|log|show|commit|add|rm|mv|tag|checkout|switch|branch|restore|reset)\b|echo\b|wc\b|cat\b|ls\b|true\b|:)'; then
    exit 0
fi

deny "BLOCKED by committer-bash-allowlist: only git read/write commands and safe shell utilities allowed for committer"
exit 0
