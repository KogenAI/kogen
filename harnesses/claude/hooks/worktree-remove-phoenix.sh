#!/usr/bin/env bash
set -euo pipefail
# worktree-remove-phoenix.sh — WorktreeRemove hook (observe-only): releases the
# port allocation recorded by worktree-create-phoenix.sh when a worktree is removed.
#
# HOOK-MANIFEST:
#   event: WorktreeRemove
#   matcher: *
#   surface: user_global
#   signal: none
#   role: all
#
# Binary-verified stdin schema (WorktreeRemove):
#   {"worktree_path": ".../.claude/worktrees/exp-slug", "cwd": "...", "hook_event_name": "WorktreeRemove"}
#   NOTE: NO worktree_name in the real schema — derive it from basename(worktree_path).

CODEGEN_DIR="${OCG_CODEGEN_DIR:-${CODEGEN_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"}}"

input=$(cat)
worktree_path=$(printf '%s' "$input" | jq -r '.worktree_path // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

if [[ -z "$worktree_path" ]]; then
    exit 0 # nothing to release; observe-only hook
fi

worktree_name="$(basename "$worktree_path")"
[[ -z "$cwd" ]] && cwd="$PWD"
project=$(basename "$cwd")

# shellcheck source=/dev/null
. "$CODEGEN_DIR/resource_manager.sh"
deallocate_resources "$project" "$worktree_name" || true

exit 0
