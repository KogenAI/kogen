#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <feature-name>"
    echo "Example: $0 dashboard-redesign"
    exit 1
fi

FEATURE_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"

REPO_ROOT="$TARGET_REPO_PATH"
WORKSPACE_PATH="${REPO_ROOT}/codegen/workspaces/${FEATURE_NAME}"

source "$SCRIPT_DIR/utils.sh"

echo "🔄 Resuming feature workspace: $FEATURE_NAME"

if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "❌ Feature workspace '$FEATURE_NAME' does not exist!"
    echo "   Use '$OCG_CMD new $FEATURE_NAME' to create it"
    echo "   Or use '$OCG_CMD ls' to see available workspaces"
    exit 1
fi

cd "$WORKSPACE_PATH"

git submodule update --init --recursive >/dev/null 2>&1

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null | cut -c1-8 || echo "unknown")

if [ -f "$WORKSPACE_PATH/.env" ]; then
    PORT=$(grep "^PORT=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
    PARTITION=$(grep "^MIX_DEV_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
else
    PORT="not configured"
    PARTITION="not configured"
fi

# Create resume flag file for startup.sh to detect
touch "$WORKSPACE_PATH/.ocg_resume"

mkdir -p "$WORKSPACE_PATH/.vscode"

if [ -f "$SCRIPT_DIR/templates/.vscode/tasks.json" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/tasks.json" "$WORKSPACE_PATH/.vscode/"
fi

if [ -f "$SCRIPT_DIR/templates/.vscode/settings.json" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/settings.json" "$WORKSPACE_PATH/.vscode/"

    if [ -f "$WORKSPACE_PATH/.env" ]; then
        WORKSPACE_PORT=$(grep "^PORT=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$WORKSPACE_PORT" ]; then
            sed -i '' "s/4000/$WORKSPACE_PORT/g" "$WORKSPACE_PATH/.vscode/settings.json"
        fi
    fi
fi

if [ -f "$SCRIPT_DIR/templates/.vscode/startup.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/startup.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/startup.sh"
    sed -i '' "s|{{DB_NAME_PREFIX}}|$DB_NAME_PREFIX|g" "$WORKSPACE_PATH/.vscode/startup.sh"
fi

if [ -f "$SCRIPT_DIR/templates/.vscode/workspace-info.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/workspace-info.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/workspace-info.sh"
fi

if [ -f "$SCRIPT_DIR/templates/.vscode/claude-code.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/claude-code.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/claude-code.sh"
fi

mkdir -p "$WORKSPACE_PATH/codegen"

if [ -f "$SCRIPT_DIR/templates/ci.sh" ]; then
    cp "$SCRIPT_DIR/templates/ci.sh" "$WORKSPACE_PATH/codegen/ci.sh"
    chmod +x "$WORKSPACE_PATH/codegen/ci.sh"
    echo "✅ Copied ci.sh for workspace-specific CI checks"
fi

if [ -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
    cp "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" "$WORKSPACE_PATH/codegen/PROJECT_CONTEXT.md"
fi

# Link to rules directory from main branch (so changes propagate)
if [ -d "$REPO_ROOT/codegen/rules" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    # Remove existing rules directory if it exists
    [ -d "$WORKSPACE_PATH/codegen/rules" ] && rm -rf "$WORKSPACE_PATH/codegen/rules"
    ln -sf "$REPO_ROOT/codegen/rules" "$WORKSPACE_PATH/codegen/rules"
    echo "✅ Linked codegen/rules from main branch (changes will propagate)"
fi

# Copy CLAUDE.md from main branch since it's gitignored
if [ -f "$REPO_ROOT/CLAUDE.md" ]; then
    cp "$REPO_ROOT/CLAUDE.md" "$WORKSPACE_PATH/CLAUDE.md"
    echo "✅ Copied CLAUDE.md from main branch"
fi

if [ -f "$SCRIPT_DIR/templates/RESUME_PROMPT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$SCRIPT_DIR/templates/RESUME_PROMPT.md" "$WORKSPACE_PATH/codegen/PROMPT.md"

    # Extract plan title
    PLAN_TITLE="$FEATURE_NAME"
    if [ -f "$WORKSPACE_PATH/codegen/PLAN.md" ]; then
        PLAN_TITLE=$(head -n 1 "$WORKSPACE_PATH/codegen/PLAN.md" | sed 's/^# *//' | sed 's/ *$//')
        PLAN_TITLE=$(echo "$PLAN_TITLE" | sed 's/[[\.*^$()+?{|&]/\\&/g')
    fi

    sed -i '' "s|{{COMMIT_HASH}}|$COMMIT_HASH|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{CURRENT_BRANCH}}|$CURRENT_BRANCH|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{FEATURE_NAME}}|$FEATURE_NAME|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAN_TITLE}}|$PLAN_TITLE|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PORT}}|$PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    PLAYWRIGHT_MCP_PORT=$(grep "^PLAYWRIGHT_MCP_PORT=" "$WORKSPACE_PATH/.env" 2>/dev/null | cut -d'=' -f2)
    sed -i '' "s|{{PLAYWRIGHT_MCP_PORT}}|$PLAYWRIGHT_MCP_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{WORKSPACE_PATH}}|$WORKSPACE_PATH|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
fi

open_cursor_workspace "$WORKSPACE_PATH" "$FEATURE_NAME" "✅ Workspace resumed successfully!"

echo ""
echo "🎯 Workspace resumed: $FEATURE_NAME"
if [ -n "$PORT" ] && [ "$PORT" != "not configured" ] && [ -n "$PLAYWRIGHT_MCP_PORT" ] && [ -n "$PARTITION" ]; then
    echo "🔌 Port: $PORT | 🎭 Playwright: $PLAYWRIGHT_MCP_PORT | 🗄️ Partition: $PARTITION | 🌿 Branch: $CURRENT_BRANCH"
fi
if [ -n "$PORT" ] && [ "$PORT" != "not configured" ]; then
    echo "🌐 Server will be available at: http://localhost:$PORT"
fi
echo "📁 $WORKSPACE_PATH"
if [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    echo "📋 Plan: codegen/plans/${FEATURE_NAME}.md"
fi
echo ""
echo "To remove: $OCG_CMD rm $FEATURE_NAME"
