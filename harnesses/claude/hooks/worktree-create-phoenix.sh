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

# Construct what Claude doesn't send (binary-verified defaults)
worktree_path="$cwd/.claude/worktrees/$name"
branch="worktree-$name"
base_ref="HEAD"
project=$(basename "$cwd")

# Step 1: Create the worktree (hook fully replaces default git logic).
git -C "$cwd" worktree add -b "$branch" "$worktree_path" "$base_ref"

# Step 2: Phoenix-specific seeding (skip for static/node stacks).
if [ -f "$cwd/mix.exs" ]; then
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

    # Step 4: Allocate a fresh port for this worktree.
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
