#!/bin/bash
# pre-commit-guard.sh — PreToolUse hook for every agent except "committer"
#
# Blocks state-modifying git commands (commit, rebase, push --force,
# reset --hard, cherry-pick, revert, merge) when the active agent is
# anything other than "committer". The orchestrator itself (agent_type
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
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging (opt-in via per-script var or the unified COMBOBULATE_HOOKS_DEBUG flag)
if [ -n "${COMBOBULATE_PRECOMMIT_DEBUG:-}" ] || [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ]; then
    printf '%s tool=%s agent=%s cmd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" "$command" \
        >>/tmp/pre-commit-guard-debug.log 2>/dev/null || true
fi

# The correct field is agent_type, not agent_name — the old comment claiming
# this was an upstream propagation bug was wrong. The guard now enforces
# correctly using agent_type. See hooks-strategy.md Issue 1 for root cause.

# Only guard Bash — git ops go through Bash exclusively.
if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

# Committer is the sole allowed writer of history.
if [ "$agent_type" = "committer" ]; then
    exit 0
fi

# State-modifying git subcommands. Notably NOT blocked: add, status, diff,
# log, show, blame, ls-files — these are routinely used for inspection by
# every subagent.
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+commit\b'; then
    printf 'BLOCKED by pre-commit-guard: git commit forbidden for agent "%s" — committer owns commit creation (see CLAUDE.md "NEVER Commit Directly")\n' "$agent_type" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+rebase\b'; then
    printf 'BLOCKED by pre-commit-guard: git rebase forbidden for agent "%s" — committer owns history\n' "$agent_type" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+cherry-pick\b'; then
    printf 'BLOCKED by pre-commit-guard: git cherry-pick forbidden for agent "%s" — committer owns history\n' "$agent_type" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+revert\b'; then
    printf 'BLOCKED by pre-commit-guard: git revert forbidden for agent "%s" — committer owns history\n' "$agent_type" >&2
    exit 2
fi

if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+merge\b'; then
    printf 'BLOCKED by pre-commit-guard: git merge forbidden for agent "%s" — committer owns history\n' "$agent_type" >&2
    exit 2
fi

# git reset --hard / --keep (destructive). Soft/mixed reset stays allowed
# for subagents that may unstage files as a read-side operation.
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+reset\b.*--hard\b'; then
    printf 'BLOCKED by pre-commit-guard: git reset --hard forbidden for agent "%s" — destructive (use stash or committer)\n' "$agent_type" >&2
    exit 2
fi

# git push --force / --force-with-lease / -f
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+push\b.*(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
    printf 'BLOCKED by pre-commit-guard: git push --force forbidden for agent "%s" — committer owns push discipline\n' "$agent_type" >&2
    exit 2
fi

exit 0
