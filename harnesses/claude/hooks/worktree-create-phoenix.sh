#!/usr/bin/env bash
set -euo pipefail
# worktree-create-phoenix.sh — WorktreeCreate hook: creates git worktree, seeds
# Phoenix _build/deps, strips port vars from .env, allocates a fresh port.
#
# HOOK-MANIFEST:
#   event: WorktreeCreate
#   matcher: *
#   surface: user_global
#   signal: none
#   role: all
#
# Binary-verified stdin schema (WorktreeCreate):
#   {"name": "exp-slug", "cwd": "...", "session_id": "...", "hook_event_name": "WorktreeCreate"}
#   NOTE: NO worktree_path, NO git_ref, NO worktree_name in the real schema.

CODEGEN_DIR="${OCG_CODEGEN_DIR:-${CODEGEN_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"}}"

input=$(cat)
name=$(printf '%s' "$input" | jq -r '.name // .worktreeName // .worktree_name // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[[ -z "$cwd" ]] && cwd="$PWD"

# Fail fast — never run git with a null/empty name
if [[ -z "$name" ]]; then
    printf '[worktree-create-phoenix] ERROR: missing .name in WorktreeCreate hook input\n' >&2
    exit 1
fi

# Construct what Claude doesn't send (binary-verified defaults).
# Canonicalize cwd so git worktree list --porcelain (absolute paths) matches.
cwd_real="$(cd "$cwd" 2>/dev/null && pwd -P || printf '%s' "$cwd")"
worktree_path="$cwd_real/.claude/worktrees/$name"
branch="worktree-$name"
base_ref="HEAD"
project=$(basename "$cwd_real")

# Step 1: Create or re-attach the worktree (hook fully replaces default git logic).
# Idempotent: a second claude-experiment <slug> run must resume, not fail with
# "fatal: a branch named '<branch>' already exists".
reattach=0
if git -C "$cwd" worktree list --porcelain 2>/dev/null |
    grep -qxF "worktree $worktree_path"; then
    # Branch A: worktree already registered → re-attach, skip add.
    printf '[worktree-create-phoenix] worktree already registered; re-attaching %s\n' "$worktree_path" >&2
    reattach=1
elif git -C "$cwd" show-ref --verify --quiet "refs/heads/$branch"; then
    # Branch B: orphaned branch (exists, no registered worktree) → attach without -b.
    git -C "$cwd" worktree add "$worktree_path" "$branch"
else
    # Branch C: neither → today's path, create branch + worktree.
    git -C "$cwd" worktree add -b "$branch" "$worktree_path" "$base_ref"
fi

# Step 2: Phoenix-specific seeding (skip for static/node stacks).
if [ -f "$cwd/mix.exs" ]; then
    if [ "$reattach" = "0" ]; then
        # Create path: seed deps, _build, and .env from parent.

        # Symlink deps (read-only during build — safe to share).
        if [ -d "$cwd/deps" ] && [ ! -e "$worktree_path/deps" ]; then
            ln -s "$cwd/deps" "$worktree_path/deps"
        fi

        # Copy _build only when parent HEAD == base_ref (same-commit guard).
        # Since base_ref=HEAD, both rev-parse calls resolve to the same SHA —
        # warm seed is always the normal path when _build exists.
        parent_sha=$(git -C "$cwd" rev-parse HEAD)
        ref_sha=$(git -C "$cwd" rev-parse "${base_ref}^{commit}" 2>/dev/null ||
            git -C "$cwd" rev-parse "$base_ref")
        if [ "$parent_sha" = "$ref_sha" ] && [ -d "$cwd/_build" ]; then
            cp -a "$cwd/_build" "$worktree_path/_build"
            # Recompile to update cwd stamp; --no-check-cwd avoids full recompile at
            # the new path (Mix 1.19.2+).
            (cd "$worktree_path" && mix compile --no-check-cwd 2>&1) ||
                printf '[worktree-create-phoenix] mix compile failed (cold compile will run on next mix invocation)\n' >&2
        else
            printf '[worktree-create-phoenix] cold compile — no warm cache (parent _build absent or at different commit)\n' >&2
        fi

        # Step 3: Copy .env stripping port/partition vars.
        if [ -f "$cwd/.env" ]; then
            grep -vE '^(PORT|PORT_TEST|MIX_DEV_PARTITION|MIX_TEST_PARTITION|API_URL)=' \
                "$cwd/.env" >"$worktree_path/.env" || true
        fi
    else
        # Reuse path: strip stale PORT lines from the existing .env so the
        # fresh port block appended below does not duplicate them.
        if [ -f "$worktree_path/.env" ]; then
            grep -vE '^(PORT|PORT_TEST|MIX_DEV_PARTITION|MIX_TEST_PARTITION|API_URL)=' \
                "$worktree_path/.env" >"$worktree_path/.env.tmp" || true
            mv "$worktree_path/.env.tmp" "$worktree_path/.env"
        fi
    fi

    # Step 4: Allocate a fresh port for this worktree (both create and reuse paths).
    # shellcheck source=/dev/null
    . "$CODEGEN_DIR/resource_manager.sh"
    port=$(allocate_phoenix_port "$project" "$name")
    {
        printf 'PORT=%s\n' "$port"
        printf 'PORT_TEST=%s\n' "$((port + 1000))"
        printf 'MIX_DEV_PARTITION=%s\n' "$name"
        printf 'MIX_TEST_PARTITION=%s\n' "$name"
    } >>"$worktree_path/.env"
fi

# Output: print path on stdout, exit 0 — required by WorktreeCreate contract.
printf '%s\n' "$worktree_path"
exit 0
