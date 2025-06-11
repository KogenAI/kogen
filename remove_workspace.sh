#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <feature-name> [--delete-branch]"
    echo "Example: $0 dashboard-redesign"
    echo "Example: $0 dashboard-redesign --delete-branch"
    exit 1
fi

FEATURE_NAME="$1"
DELETE_BRANCH=false

if [ "$2" = "--delete-branch" ]; then
    DELETE_BRANCH=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"

REPO_ROOT="$TARGET_REPO_PATH"
WORKSPACE_NAME="${FEATURE_NAME}"
WORKSPACE_PATH="${REPO_ROOT}/codegen/workspaces/${WORKSPACE_NAME}"
BRANCH_NAME="feature/${FEATURE_NAME}"

echo "🗑️  Removing feature workspace for: $FEATURE_NAME"

if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "❌ Error: Feature workspace directory does not exist: $WORKSPACE_PATH"
    exit 1
fi

cd "$WORKSPACE_PATH"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "⚠️  Warning: Uncommitted changes will be lost!"
    git status --short
    echo ""
fi

UNPUSHED=$(git log --oneline @{u}.. 2>/dev/null | wc -l || echo "0")
if [ "$UNPUSHED" -gt 0 ]; then
    echo "⚠️  Warning: $UNPUSHED unpushed commit(s) will be lost!"
    echo ""
fi

DEV_PARTITION=""
TEST_PARTITION=""
if [ -f "$WORKSPACE_PATH/.env" ]; then
    DEV_PARTITION=$(grep "^MIX_DEV_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
    TEST_PARTITION=$(grep "^MIX_TEST_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
fi

cd "$REPO_ROOT"
git worktree remove --force "$WORKSPACE_PATH" >/dev/null 2>&1

if [ -n "$DEV_PARTITION" ] || [ -n "$TEST_PARTITION" ]; then
    if [ -n "$DEV_PARTITION" ]; then
        MIX_DEV_PARTITION=$DEV_PARTITION mix ecto.drop >/dev/null 2>&1 || true
    fi
    if [ -n "$TEST_PARTITION" ]; then
        MIX_ENV=test MIX_TEST_PARTITION=$TEST_PARTITION mix ecto.drop >/dev/null 2>&1 || true
    fi
fi

if [ "$DELETE_BRANCH" = true ]; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
        git branch -D "$BRANCH_NAME" >/dev/null 2>&1
    fi
fi

echo ""
echo "🎉 Workspace removed: $FEATURE_NAME"
if [ "$DELETE_BRANCH" = true ]; then
    echo "🌿 Branch deleted: $BRANCH_NAME"
else
    echo "🌿 Branch preserved: $BRANCH_NAME"
    echo "   To remove the branch: git branch -D $BRANCH_NAME"
fi
