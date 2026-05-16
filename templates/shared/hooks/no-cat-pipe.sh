#!/bin/bash
# no-cat-pipe.sh — PreToolUse hook: deny `cat FILE | head|tail|grep|less|more`.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
#
# Blocks: cat file | head, cat file | tail, cat file | grep, cat file | less,
#         cat file | more.
#
# Allows: cat file.txt (no pipe), echo x | cat, cat <<EOF (heredoc),
#         multi-file cat without pipe.
#
# Rationale: truncation via head/tail hides relevant lines. Use Read tool with
# offset/limit. Use Grep tool instead of cat | grep.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log no-cat-pipe "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Deny: `cat <file> | head|tail|grep|less|more`.
# Pattern: cat followed by a non-pipe token (the file), optional whitespace,
# a pipe, then one of the truncating/searching tools.
if printf '%s' "$COMMAND" | grep -qE 'cat[[:space:]]+[^|]*\|[[:space:]]*(head|tail|grep|less|more)\b'; then
    deny "Use Read tool with offset/limit instead of \`cat | head/tail\`. Use Grep tool instead of \`cat | grep\`. Truncation hides relevant lines."
    exit 0
fi

exit 0
