#!/bin/bash
# context-index-parity.sh — PreToolUse hook: deny `git commit` when staged diff
# adds or removes a `context/*.md` file without also modifying the repo's
# PROJECT_CONTEXT.md (platform layout) or codegen/PROJECT_CONTEXT.md (user-app layout).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: unset
#
# Firing contract: no CLAUDE_ROLE gating (signal: none) — fires for all roles in all repos.
# Subagent inheritance: intentional — committer runs as subagent and this hook MUST
#   block its commits. Do NOT call is_outer_session().
#
# Blocks: git commit (any form) when context/*.md is added (A) or deleted (D) in
#         the staged index and the detected index file is NOT also staged.
#
# Allows:
#   - git commit when context/*.md is only modified (M), renamed (R), or type-changed (T)
#   - git commit when the detected index file is also staged
#   - git commit with no context/*.md changes
#   - git status, git log, echo "git commit" (non-commit or substring)
#   - Read/Write/Edit tools (non-Bash)
#   - Any command outside a git repo (no .git dir) or repo with no PROJECT_CONTEXT.md
#
# Repo layout detection (checked at repo root, in priority order):
#   1. PROJECT_CONTEXT.md          — platform layout (e.g. combobulate)
#   2. codegen/PROJECT_CONTEXT.md  — user-app layout (project using OCG)
#   If neither exists → exit 0 (repo not in scope)
#
# Rationale: PROJECT_CONTEXT.md § Domain Context Files must stay in sync with the
# set of context/*.md files. Adding or removing a context/*.md without updating
# the index row creates stale documentation.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-index-parity "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Match git commit at start-of-command position (not inside echo/string).
# Matches: git commit, git commit -m "x", git commit --amend
# Does NOT match: echo "git commit", git status
if ! printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&|])git[[:space:]]+commit\b'; then
    exit 0
fi

# Guard: must be inside a git repo.
if [ -z "$CWD" ] || ! git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

# Derive repo root from CWD.
repo_root=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
    exit 0
fi

# Detect layout and resolve index file path.
# Priority: platform layout (PROJECT_CONTEXT.md) first, then user-app layout.
if [ -f "$repo_root/PROJECT_CONTEXT.md" ]; then
    index_path="PROJECT_CONTEXT.md"
elif [ -f "$repo_root/codegen/PROJECT_CONTEXT.md" ]; then
    index_path="codegen/PROJECT_CONTEXT.md"
else
    # Repo not in scope — no-op.
    exit 0
fi

# Find context/*.md files that are Added or Deleted in the staged index.
# Filter: only direct children of context/ — no subdirectory traversal.
orphan_files=$(git -C "$repo_root" diff --cached --name-status 2>/dev/null |
    grep -E '^[AD][[:space:]]+context/[^/]+\.md$' |
    awk '{print $2}' ||
    true)

# No orphan adds/deletes → allow.
if [ -z "$orphan_files" ]; then
    exit 0
fi

# Check whether the index file is also staged.
index_staged=$(git -C "$repo_root" diff --cached --name-status -- "$index_path" 2>/dev/null || true)

if [ -n "$index_staged" ]; then
    # Index file is also staged → allow.
    exit 0
fi

# Build a comma-separated list of offending files for the deny message.
offending=$(printf '%s' "$orphan_files" | tr '\n' ' ' | sed 's/[[:space:]]*$//')

deny "context-index-parity: staged diff adds/removes context/*.md without updating $index_path.

Offending files: $offending

Fix: add or remove the matching row in the '§ Domain Context Files' section of $index_path, then re-stage it before committing."
exit 0
