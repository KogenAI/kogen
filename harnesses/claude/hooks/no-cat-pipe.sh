#!/bin/bash
# no-cat-pipe.sh — PreToolUse hook: deny `cat FILE | head|tail|grep|less|more`.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
# harnesses: all
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log no-cat-pipe "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

_role=$(resolve_role)
for _m in ops; do [ "$_role" = "$_m" ] && exit 0; done

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Deny: pattern match.
if printf '%s' "$COMMAND" | grep -qE 'cat[[:space:]]+[^|]*\|[[:space:]]*(head|tail|grep|less|more)\b'; then
    deny "Use Read tool with offset/limit instead of \`cat | head/tail\`. Use Grep tool instead of \`cat | grep\`. Truncation hides relevant lines."
    exit 0
fi

exit 0
