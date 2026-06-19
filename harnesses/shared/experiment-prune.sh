#!/usr/bin/env bash
# experiment-prune.sh — idempotent teardown for an experiment worktree.
# Defines experiment_prune <slug>: removes .claude/worktrees/exp-<slug>, deletes
# branch worktree-exp-<slug>, releases the Phoenix port (project=basename(PWD),
# workspace=exp-<slug>), and runs `git worktree prune`. Every step fail-open so
# re-running or partial state never errors. Sourced by claude-experiment.sh and
# pi-experiment.sh; expects CODEGEN_DIR exported by the caller.
#
# Returns: 0 on success (one-line summary on stdout); 1 when no exp-<slug>
# worktree dir AND no worktree-exp-<slug> branch exists (no-op).
set -uo pipefail # NOTE: no -e — fail-open steps must not abort the function

experiment_prune() {
    local slug="$1"
    # Sanitize: strip a single leading exp- so exp-exp-<slug> never forms.
    slug="${slug#exp-}"
    local wt=".claude/worktrees/exp-${slug}"
    local branch="worktree-exp-${slug}"

    # Found = dir OR branch exists; else no-op error.
    if [ ! -d "$wt" ] && ! git show-ref --verify --quiet "refs/heads/${branch}"; then
        printf "no experiment 'exp-%s' found\n" "$slug" >&2
        return 1
    fi

    git worktree remove --force "$wt" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true

    # shellcheck source=/dev/null
    . "${CODEGEN_DIR}/resource_manager.sh"
    deallocate_resources "$(basename "$PWD")" "exp-${slug}" >/dev/null 2>&1 || true

    git worktree prune 2>/dev/null || true

    printf 'pruned exp-%s: worktree removed, branch deleted, port released\n' "$slug"
    return 0
}
