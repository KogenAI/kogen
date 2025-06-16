#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

REPO_ROOT="$TARGET_REPO_PATH"
PARENT_DIR="$(dirname "$REPO_ROOT")"

echo "🌳 Optimum Codegen Feature Workspaces Overview"
echo "======================================="
echo ""

cd "$REPO_ROOT"
WORKSPACES=$(git worktree list --porcelain)

if [ -z "$WORKSPACES" ]; then
    echo "No feature workspaces found."
    exit 0
fi

echo "$WORKSPACES" | while IFS= read -r line; do
    if [[ $line == worktree* ]]; then
        WORKSPACE_PATH=$(echo "$line" | cut -d' ' -f2)
        WORKSPACE_NAME=$(basename "$WORKSPACE_PATH")

        read -r BRANCH_LINE
        read -r HEAD_LINE

        BRANCH=$(echo "$BRANCH_LINE" | cut -d' ' -f2)

        cd "$WORKSPACE_PATH"
        COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null | cut -c1-8)
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
        cd "$REPO_ROOT"

        if [ -n "$CURRENT_BRANCH" ]; then
            DISPLAY_BRANCH="$CURRENT_BRANCH"
        else
            DISPLAY_BRANCH="$BRANCH"
        fi

        if [ "$WORKSPACE_PATH" = "$REPO_ROOT" ]; then
            echo "📁 Main Repository"
        else
            echo "📁 $WORKSPACE_NAME"
        fi

        echo "   📍 Path: $WORKSPACE_PATH"
        echo "   🌿 Branch: $DISPLAY_BRANCH"
        echo "   📝 HEAD: $COMMIT_HASH"

        if [ -f "$WORKSPACE_PATH/.env" ]; then
            PORT=$(grep "^PORT=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
            DEV_PARTITION=$(grep "^MIX_DEV_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
            TEST_PARTITION=$(grep "^MIX_TEST_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)

            if [ -n "$PORT" ]; then

                if lsof -i :$PORT >/dev/null 2>&1; then
                    echo "   🔌 Port: $PORT (🟢 in use)"
                else
                    echo "   🔌 Port: $PORT (⚪ available)"
                fi
            else

                if [ "$WORKSPACE_PATH" = "$REPO_ROOT" ]; then
                    echo "   🔌 Port: 4000 (default)"
                else
                    echo "   🔌 Port: not configured"
                fi
            fi

            if [ -n "$DEV_PARTITION" ]; then
                echo "   🗄️  Database (dev): ${DB_NAME_PREFIX}_dev$DEV_PARTITION"
            else
                echo "   🗄️  Database (dev): ${DB_NAME_PREFIX}_dev (default)"
            fi

            if [ -n "$TEST_PARTITION" ]; then
                echo "   🗄️  Database (test): ${DB_NAME_PREFIX}_test$TEST_PARTITION"
            else
                echo "   🗄️  Database (test): ${DB_NAME_PREFIX}_test (default)"
            fi
        else

            if [ "$WORKSPACE_PATH" = "$REPO_ROOT" ]; then
                echo "   🔌 Port: 4000 (default)"
            else
                echo "   🔌 Port: no .env file"
            fi
            echo "   🗄️  Database (dev): ${DB_NAME_PREFIX}_dev (default)"
            echo "   🗄️  Database (test): ${DB_NAME_PREFIX}_test (default)"
        fi

        if [ "$WORKSPACE_PATH" != "$REPO_ROOT" ] && [ -d "$WORKSPACE_PATH" ]; then
            cd "$WORKSPACE_PATH"

            if ! git diff --quiet -- ':!.cursor/mcp.json' || ! git diff --cached --quiet -- ':!.cursor/mcp.json'; then
                echo "   ⚠️  Uncommitted changes"
            fi

            UNPUSHED=$(git log --oneline @{u}.. 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            if [ "$UNPUSHED" -gt 0 ]; then
                echo "   📤 $UNPUSHED unpushed commit(s)"
            fi

            cd "$REPO_ROOT"
        fi

        echo ""
    fi
done

echo "💡 Tips:"
echo "   • Create new feature workspace: $OCG_CMD new <feature-name> (auto-starts server)"
echo "   • Resume existing workspace: $OCG_CMD resume <feature-name>"
echo "   • Remove feature workspace: $OCG_CMD rm <feature-name>"
echo "   • Show all commands: $OCG_CMD help"
