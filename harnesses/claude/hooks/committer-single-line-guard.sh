#!/bin/bash
# committer-single-line-guard.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks git commit -m "..." where the -m payload contains a literal \n
# (two chars: backslash + n) or an actual 0x0A newline byte.
# Multi-line commit messages must not be passed inline via -m.
#
# Pass-through: if no -m flag found, defer to committer-no-trailer-guard.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-single-line-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate the committer
if [ "$AGENT_TYPE" != "committer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Only inspect git commit commands
if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

# Early check: if COMMAND itself contains actual 0x0A newlines AND contains git commit,
# it likely has an embedded newline in the -m payload.
# wc -l counts lines (n newlines = n+1 lines), so >0 means at least one newline present.
if [ "$(printf '%s' "$COMMAND" | wc -l | tr -d ' ')" -gt 0 ]; then
    deny "BLOCKED by committer-single-line-guard: git commit command contains actual newline. Use a single-line subject only."
    exit 0
fi

# Deny if COMMAND contains literal \n (backslash + n) in any -m argument
if printf '%s' "$COMMAND" | grep -qF '\n'; then
    deny "BLOCKED by committer-single-line-guard: commit -m payload contains literal \\n. Use a single-line subject only."
    exit 0
fi

# Extract commit message from -m flag (single or double quoted)
# Same regex as committer-subject-length.sh
msg=$(printf '%s' "$COMMAND" | grep -oE -- '-m[[:space:]]+("([^"]+)"|'"'"'([^'"'"']+)'"'"')' | head -1 | sed -E 's/-m[[:space:]]+["'"'"']//; s/["'"'"']$//')

# No -m flag found → pass-through (committer-no-trailer-guard owns that case)
if [ -z "$msg" ]; then
    exit 0
fi

exit 0
