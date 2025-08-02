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
source "$SCRIPT_DIR/docker_utils.sh"
source "$SCRIPT_DIR/resource_manager.sh"

REPO_ROOT="$TARGET_REPO_PATH"
PROJECT_NAME="$REPO_NAME"
WORKSPACE_NAME="${FEATURE_NAME}"
WORKSPACE_PATH="${REPO_ROOT}/codegen/workspaces/${WORKSPACE_NAME}"
BRANCH_NAME="feature/${FEATURE_NAME}"

echo "🗑️  Removing feature workspace for: $FEATURE_NAME"

if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "❌ Error: Feature workspace directory does not exist: $WORKSPACE_PATH"
    exit 1
fi

# Archive context FIRST (before any cleanup)
if [ -f "$WORKSPACE_PATH/codegen/CONTEXT.md" ]; then
    mkdir -p "$REPO_ROOT/codegen/contexts"
    cp "$WORKSPACE_PATH/codegen/CONTEXT.md" "$REPO_ROOT/codegen/contexts/${FEATURE_NAME}.md"
    echo "📦 Archived feature context to: codegen/contexts/${FEATURE_NAME}.md"
fi

# Deallocate global resources for this workspace
echo "🌐 Deallocating global resources..."
deallocate_resources "$PROJECT_NAME" "$WORKSPACE_NAME"

# Check for Docker workspace BEFORE removing anything
IS_DOCKER_WORKSPACE=false
if [ -f "$WORKSPACE_PATH/codegen/docker-compose.yml" ]; then
    IS_DOCKER_WORKSPACE=true
fi

# Docker cleanup if container exists
if [ "$IS_DOCKER_WORKSPACE" = true ]; then
    # Check if Docker daemon is running
    if docker info &>/dev/null; then
        echo "🐳 Checking for Docker container..."
        CONTAINER_NAME="ocg-${PROJECT_NAME}-${FEATURE_NAME}"
        if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo "🧹 Stopping and removing Docker container..."
            cd "$WORKSPACE_PATH"
            docker compose -f codegen/docker-compose.yml down -v 2>/dev/null || true
            cd "$REPO_ROOT"
            echo "✅ Docker container and volumes removed"
        fi

        # Ensure volumes are removed even if container doesn't exist
        echo "🧹 Cleaning up Docker volumes..."
        docker volume rm "ocg-${PROJECT_NAME}-deps-${FEATURE_NAME}" 2>/dev/null || true
        docker volume rm "ocg-${PROJECT_NAME}-build-${FEATURE_NAME}" 2>/dev/null || true
        docker volume rm "ocg-${PROJECT_NAME}-node-${FEATURE_NAME}" 2>/dev/null || true
        docker volume rm "ocg-${PROJECT_NAME}-plts-${FEATURE_NAME}" 2>/dev/null || true
    else
        echo "❌ ERROR: Docker daemon is not running!"
        echo ""
        echo "Docker is required to properly clean up workspace volumes and containers."
        echo "Without Docker cleanup, the workspace removal will leave behind files"
        echo "with Docker-owned permissions that cannot be removed normally."
        echo ""
        echo "Please start Docker Desktop and try again:"
        echo "   1. Start Docker Desktop"
        echo "   2. Wait for it to be ready"
        echo "   3. Run: ocg rm $FEATURE_NAME"
        echo ""
        exit 1
    fi
fi

# Check if workspace is still a valid git worktree
if git -C "$WORKSPACE_PATH" rev-parse --git-dir &>/dev/null; then
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
else
    echo "⚠️  Workspace is not a valid git repository, skipping git status check"
fi

DEV_PARTITION=""
TEST_PARTITION=""
if [ -f "$WORKSPACE_PATH/.env" ]; then
    DEV_PARTITION=$(grep "^MIX_DEV_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
    TEST_PARTITION=$(grep "^MIX_TEST_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
fi

# Drop databases BEFORE removing the worktree
if [ -n "$DEV_PARTITION" ] || [ -n "$TEST_PARTITION" ]; then
    echo "🗑️  Dropping workspace databases..."
    cd "$REPO_ROOT"
    if [ -n "$DEV_PARTITION" ]; then
        MIX_DEV_PARTITION=$DEV_PARTITION mix ecto.drop >/dev/null 2>&1 || true
    fi
    if [ -n "$TEST_PARTITION" ]; then
        MIX_ENV=test MIX_TEST_PARTITION=$TEST_PARTITION mix ecto.drop >/dev/null 2>&1 || true
    fi
    echo "✅ Databases dropped"
fi

# Remove git worktree last (this deletes the workspace directory)
cd "$REPO_ROOT"

# No need to restore .git file anymore since we use git worktree repair

# First try to remove the worktree (it might fail if directory was already removed by Docker)
if ! git worktree remove "$WORKSPACE_NAME" >/dev/null 2>&1; then
    # If that fails, try with force
    if ! git worktree remove "$WORKSPACE_NAME" --force >/dev/null 2>&1; then
        echo "⚠️  Failed to remove git worktree, attempting manual cleanup..."
        # Try one more time without suppressing output to see what's wrong
        git worktree remove "$WORKSPACE_NAME" --force || true
    fi
fi

# Always try to remove the directory if it still exists
if [ -d "$WORKSPACE_PATH" ]; then
    rm -rf "$WORKSPACE_PATH"
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
