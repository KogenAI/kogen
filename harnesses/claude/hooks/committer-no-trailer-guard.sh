#!/bin/bash
# committer-no-trailer-guard.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks git commit commands that lack a -m "..." flag.
# Allows: git commit -m "...", git commit --amend -m "..."
# Blocks:  bare git commit, git commit --file, git commit -F

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-no-trailer-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

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
if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit([[:space:];&|]|$)'; then
    exit 0
fi

# Allow if -m flag is present (covers `-m "..."`, `-m'...'`, and the
# no-space forms `-m"..."`/`-m'...'`); also covers `git commit --amend -m ...`.
if printf '%s' "$COMMAND" | grep -qE "\\bgit[[:space:]]+commit[[:space:]].*-m['\"[:space:]]"; then
    exit 0
fi

# --file or -F forms — denied
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit[[:space:]].*(-F[[:space:]]|--file[[:space:]])'; then
    deny "BLOCKED by committer-no-trailer-guard: git commit --file/-F not allowed. Use -m \"subject\" with inline message."
    exit 0
fi

# Bare git commit (no -m) — denied
deny "BLOCKED by committer-no-trailer-guard: git commit requires -m \"subject\". Use: git commit -m \"subject line\""
exit 0
