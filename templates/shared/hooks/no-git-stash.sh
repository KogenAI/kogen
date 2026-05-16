#!/bin/bash
# no-git-stash.sh — PreToolUse hook: deny any `git stash` invocation.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
#
# Blocks: git stash / git stash push / git stash pop / git stash list / etc.
#
# Allows: git status, git log (even with --stash flag — not a stash subcommand).
#
# Rationale: stash hides WIP from orchestrator + reviewer. Commit WIP to a
# scratch branch or use worktrees instead.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log no-git-stash "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Deny: any `git stash` subcommand.
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+stash\b'; then
    deny "git stash forbidden. Commit WIP to a scratch branch or use worktrees. Stash hides work from orchestrator + reviewer."
    exit 0
fi

exit 0
