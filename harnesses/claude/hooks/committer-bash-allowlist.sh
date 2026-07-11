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

# Allowlist: split command into unquoted-chained segments; EVERY segment
# must match the allowlist. Prevents an allowed prefix (e.g. `ls`) chained
# via && / ; / | / & to a forbidden command from bypassing the gate.
if ! _segs=$(split_command_segments "$COMMAND"); then
    deny "BLOCKED by committer-bash-allowlist: only git read/write commands and safe shell utilities allowed for committer"
    exit 0
fi
while IFS= read -r _seg; do
    _trimmed=$(printf '%s' "$_seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$_trimmed" ] && continue
    if ! printf '%s' "$_trimmed" | grep -qE '^[[:space:]]*(cd\b|git[[:space:]]+(-C[[:space:]]+\S+[[:space:]]+)?(diff|status|log|show|commit|add|rm|mv|tag|checkout|switch|branch|restore|reset)\b|codegen-log\b|printf\b|echo\b|wc\b|cat\b|ls\b|true\b|:)'; then
        deny "BLOCKED by committer-bash-allowlist: only git read/write commands and safe shell utilities allowed for committer"
        exit 0
    fi
done <<<"$_segs"
exit 0
