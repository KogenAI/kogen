#!/bin/bash
# pre-commit-guard.sh — PreToolUse hook for every agent except "committer"
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
#
# Blocks state-modifying git commands (commit, rebase, push --force,
# reset --hard, cherry-pick, revert, merge) when the active agent is
# anything other than "committer". The orchestrator itself (agent_type
# is "") is also blocked — per CLAUDE.md only the committer may touch
# history.
#
# Ops mode (CLAUDE_ROLE=ops / PI_ROLE=ops) bypasses entirely — full git
# surface, no restriction (interactive ops on live boxes).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log pre-commit-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# ops mode bypasses: full git surface for interactive ops on live boxes.
_role=$(resolve_role)
[ "$_role" = "ops" ] && exit 0

# Only guard Bash — git ops go through Bash exclusively.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Committer is the sole allowed writer of history.
if [ "$AGENT_TYPE" = "committer" ]; then
    exit 0
fi

# State-modifying git subcommands. Notably NOT blocked: add, status, diff,
# log, show, blame, ls-files — these are routinely used for inspection by
# every subagent.
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    deny "BLOCKED by pre-commit-guard: git commit forbidden for agent \"$AGENT_TYPE\" — committer owns commit creation (see CLAUDE.md \"NEVER Commit Directly\")"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+rebase\b'; then
    deny "BLOCKED by pre-commit-guard: git rebase forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+cherry-pick\b'; then
    deny "BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+revert\b'; then
    deny "BLOCKED by pre-commit-guard: git revert forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+merge\b'; then
    deny "BLOCKED by pre-commit-guard: git merge forbidden for agent \"$AGENT_TYPE\" — committer owns history"
    exit 0
fi

# git reset --hard / --keep (destructive). Soft/mixed reset stays allowed
# for subagents that may unstage files as a read-side operation.
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
    deny "BLOCKED by pre-commit-guard: git reset --hard forbidden for agent \"$AGENT_TYPE\" — destructive (use stash or committer)"
    exit 0
fi

# git push --force / --force-with-lease / -f
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+push\b.*(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
    deny "BLOCKED by pre-commit-guard: git push --force forbidden for agent \"$AGENT_TYPE\" — committer owns push discipline"
    exit 0
fi

exit 0
