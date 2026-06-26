#!/bin/bash
# context-index-parity.sh — PreToolUse hook: deny `git commit` when staged diff
# adds or removes a `context/*.md` file without semantic registration parity in the
# repo's PROJECT_CONTEXT.md (platform layout) or codegen/PROJECT_CONTEXT.md (user-app).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: unset
# harnesses: all
#
# Firing contract: no CLAUDE_ROLE gating (signal: none) — fires for all roles in all repos.
# Subagent inheritance: intentional — committer runs as subagent and this hook MUST
#   block its commits. Do NOT call is_outer_session().
#
# Blocks: git commit (any form) when context/*.md is added (A) or deleted (D) and
#         the about-to-be-committed index body lacks semantic registration parity:
#           ADD direction — index must be staged AND its staged body must mention
#                           the added file's basename.
#           DELETE direction — the about-to-be-committed index body (staged blob if
#                              staged, HEAD blob otherwise) must NOT mention the
#                              deleted file's basename.
#
# Allows:
#   - git commit when context/*.md is only modified (M), renamed (R), or type-changed (T)
#   - git commit when every added context/*.md basename appears in the staged index body
#   - git commit when every deleted context/*.md basename is absent from the committed index body
#   - git commit with no context/*.md changes
#   - git status, git log, echo "git commit" (non-commit or substring)
#   - Read/Write/Edit tools (non-Bash)
#   - Any command outside a git repo (no .git dir) or repo with no PROJECT_CONTEXT.md
#
# Repo layout detection (checked at repo root, in priority order):
#   1. PROJECT_CONTEXT.md          — platform layout (e.g. the build platform)
#   2. codegen/PROJECT_CONTEXT.md  — user-app layout (project using OCG)
#   If neither exists → exit 0 (repo not in scope)
#
# Rationale: PROJECT_CONTEXT.md § Domain Context Files must stay in sync with the
# set of context/*.md files. The staged/committed index body is the canonical source
# of truth — merely staging the index file is not enough; the added basename must
# actually appear in it (and a deleted basename must be removed from it).

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

# Determine whether the index file is staged (boolean: non-empty → staged).
index_staged=$(git -C "$repo_root" diff --cached --name-only -- "$index_path" 2>/dev/null || true)

# No orphan adds/deletes AND index not staged → nothing to check.
if [ -z "$orphan_files" ] && [ -z "$index_staged" ]; then
    exit 0
fi

# Resolve index body for each direction (lazily, with error guard).
# ADD direction: staged blob (the commit captures the staged version).
# DELETE direction: staged blob if staged, else committed HEAD blob.
staged_body=""
head_body=""

if [ -n "$index_staged" ]; then
    staged_body=$(git -C "$repo_root" show :"$index_path" 2>/dev/null || true)
else
    head_body=$(git -C "$repo_root" show HEAD:"$index_path" 2>/dev/null || true)
fi

# Per-file semantic parity loop.
add_missing=""
delete_stale=""

while IFS= read -r fpath; do
    [ -z "$fpath" ] && continue

    # Split status and basename from --name-status output line, e.g. "A	context/foo.md".
    status=$(git -C "$repo_root" diff --cached --name-status 2>/dev/null |
        awk -v p="$fpath" '$2 == p {print substr($1,1,1); exit}' || true)
    basename="${fpath%.md}"
    basename="${basename##*/}"

    if [ "$status" = "A" ]; then
        # ADD: index must be staged AND its staged body must mention the basename.
        if [ -z "$index_staged" ]; then
            add_missing="${add_missing}${add_missing:+$'\n'}context-index-parity: context/${basename}.md added but $index_path is not staged. Stage $index_path with a \"Load when prompt mentions...\" row for \"${basename}\" in § Domain Context Files."
        else
            if ! printf '%s' "$staged_body" | grep -qF "$basename"; then
                add_missing="${add_missing}${add_missing:+$'\n'}context-index-parity: context/${basename}.md added but no index row mentions \"${basename}\" in ${index_path} § Domain Context Files. Add a \"Load when prompt mentions...\" row."
            fi
        fi
    elif [ "$status" = "D" ]; then
        # DELETE: the about-to-be-committed index body must NOT mention the basename.
        if [ -n "$index_staged" ]; then
            check_body="$staged_body"
        else
            check_body="$head_body"
        fi
        if printf '%s' "$check_body" | grep -qF "$basename"; then
            delete_stale="${delete_stale}${delete_stale:+$'\n'}context-index-parity: context/${basename}.md deleted but a stale index row still mentions \"${basename}\". Remove it."
        fi
    fi
done <<EOF
$orphan_files
EOF

# Build combined deny message if any violations found.
violations=""
[ -n "$add_missing" ] && violations="$add_missing"
if [ -n "$delete_stale" ]; then
    violations="${violations}${violations:+$'\n\n'}${delete_stale}"
fi

# Existence pass: scan the staged (or HEAD) index body for all context/<name>.md
# references and deny if any referenced file does not exist on disk.
# Trigger: only when the index file is staged (PROJECT_CONTEXT.md is being updated).
phantom_refs=""
if [ -n "$index_staged" ] && [ -n "$staged_body" ]; then
    ref_names=$(printf '%s' "$staged_body" | grep -oE 'context/[a-z0-9_-]+\.md' | sort -u || true)
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        if [ ! -f "$repo_root/$ref" ]; then
            phantom_refs="${phantom_refs}${phantom_refs:+$'\n'}context-index-parity: $index_path row references $ref which does not exist. Add the file or remove the row."
        fi
    done <<EOF2
$ref_names
EOF2
fi

if [ -n "$phantom_refs" ]; then
    violations="${violations}${violations:+$'\n\n'}${phantom_refs}"
fi

if [ -n "$violations" ]; then
    deny "$violations"
fi
exit 0
