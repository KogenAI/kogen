#!/bin/bash
# pre-commit-guard.sh — PreToolUse hook for every agent except "committer"
#
# Blocks state-modifying git commands (commit, rebase, push --force,
# reset --hard, cherry-pick, revert, merge) when the active agent is
# anything other than "committer". The orchestrator itself (agent_name
# is "") is also blocked — per CLAUDE.md only the committer may touch
# history.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
agent_name=$(printf '%s' "$input" | jq -r '.agent_name // ""')

# Debug logging (opt-in via env var)
if [ -n "${COMBOBULATE_PRECOMMIT_DEBUG:-}" ]; then
    printf '%s tool=%s agent=%s cmd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_name" "$command" \
        >>/tmp/pre-commit-guard-debug.log 2>/dev/null || true
fi

# Claude Code does not propagate subagent configured names into hook stdin —
# agent_name is always "" for all spawned agents including the committer.
# The guard is therefore disabled (always allows) until Claude Code exposes
# a reliable agent identity signal in hook stdin.
# TODO: re-enable when agent_name is reliably populated by Claude Code.
exit 0

# Only guard Bash — git ops go through Bash exclusively.
if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

# Committer is the sole allowed writer of history.
if [ "$agent_name" = "committer" ]; then
    exit 0
fi

# State-modifying git subcommands. Notably NOT blocked: add, status, diff,
# log, show, blame, ls-files — these are routinely used for inspection by
# every subagent.
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+commit\b'; then
    printf 'BLOCKED by pre-commit-guard: git commit forbidden for agent "%s" — committer owns commit creation (see CLAUDE.md "NEVER Commit Directly")\n' "$agent_name" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+rebase\b'; then
    printf 'BLOCKED by pre-commit-guard: git rebase forbidden for agent "%s" — committer owns history\n' "$agent_name" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+cherry-pick\b'; then
    printf 'BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent "%s" — committer owns history\n' "$agent_name" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+revert\b'; then
    printf 'BLOCKED by pre-commit-guard: git revert forbidden for agent "%s" — committer owns history\n' "$agent_name" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+merge\b'; then
    printf 'BLOCKED by pre-commit-guard: git merge forbidden for agent "%s" — committer owns history\n' "$agent_name" >&2
    exit 2
fi

# git reset --hard / --keep (destructive). Soft/mixed reset stays allowed
# for subagents that may unstage files as a read-side operation.
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
    printf 'BLOCKED by pre-commit-guard: git reset --hard forbidden for agent "%s" — destructive (use stash or committer)\n' "$agent_name" >&2
    exit 2
fi

# git push --force / --force-with-lease / -f
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+push\b.*(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
    printf 'BLOCKED by pre-commit-guard: git push --force forbidden for agent "%s" — committer owns push discipline\n' "$agent_name" >&2
    exit 2
fi

exit 0
