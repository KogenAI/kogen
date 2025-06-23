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
source "$SCRIPT_DIR/utils.sh"

REPO_ROOT="$TARGET_REPO_PATH"
WORKSPACE_NAME="${FEATURE_NAME}"
WORKSPACE_PATH="${REPO_ROOT}/codegen/workspaces/${WORKSPACE_NAME}"
BRANCH_NAME="feature/${FEATURE_NAME}"

echo "🌳 Creating feature workspace for: $FEATURE_NAME"

mkdir -p "$REPO_ROOT/codegen/workspaces"

if [ -d "$WORKSPACE_PATH" ]; then
    echo "💡 Feature workspace '$FEATURE_NAME' already exists!"
    echo "   Use '$OCG_CMD resume $FEATURE_NAME' to reopen it in Cursor"
    echo "   Or use '$OCG_CMD rm $FEATURE_NAME' to remove and recreate it"
    exit 0
fi

get_next_port() {
    local base_port=4001
    local current_port=$base_port

    while true; do
        local port_in_use=false

        for workspace_dir in "$REPO_ROOT"/codegen/workspaces/*; do
            if [ -d "$workspace_dir" ] && [ -f "$workspace_dir/.env" ]; then
                if grep -q "^PORT=$current_port" "$workspace_dir/.env" 2>/dev/null; then
                    port_in_use=true
                    break
                fi
            fi
        done

        if ! $port_in_use && lsof -i :$current_port >/dev/null 2>&1; then
            port_in_use=true
        fi

        if ! $port_in_use; then
            echo $current_port
            return
        fi

        ((current_port++))

        if [ $current_port -gt 4100 ]; then
            echo "❌ Error: Could not find available port (checked up to 4100)"
            exit 1
        fi
    done
}

get_next_playwright_port() {
    local base_port=8901
    local current_port=$base_port

    while true; do
        local port_in_use=false

        for workspace_dir in "$REPO_ROOT"/codegen/workspaces/*; do
            if [ -d "$workspace_dir" ] && [ -f "$workspace_dir/.env" ]; then
                if grep -q "^PLAYWRIGHT_MCP_PORT=$current_port" "$workspace_dir/.env" 2>/dev/null; then
                    port_in_use=true
                    break
                fi
            fi
        done

        if ! $port_in_use && lsof -i :$current_port >/dev/null 2>&1; then
            port_in_use=true
        fi

        if ! $port_in_use; then
            echo $current_port
            return
        fi

        ((current_port++))

        if [ $current_port -gt 9000 ]; then
            echo "❌ Error: Could not find available Playwright MCP port (checked up to 9000)"
            exit 1
        fi
    done
}

echo "📁 Creating feature workspace at: $WORKSPACE_PATH"
cd "$REPO_ROOT"

if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    git worktree add "$WORKSPACE_PATH" "$BRANCH_NAME" >/dev/null 2>&1
else
    git worktree add "$WORKSPACE_PATH" -b "$BRANCH_NAME" >/dev/null 2>&1
fi

cd "$WORKSPACE_PATH"

git submodule update --init --recursive >/dev/null 2>&1

echo "📦 Workspace created - setup will happen in the new workspace"
echo ""

NEXT_PORT=$(get_next_port)
NEXT_PLAYWRIGHT_PORT=$(get_next_playwright_port)
PARTITION=$((NEXT_PORT - 4000))

if [ -f "$REPO_ROOT/.env" ]; then
    cp "$REPO_ROOT/.env" "$WORKSPACE_PATH/.env"
    echo "" >>"$WORKSPACE_PATH/.env"
fi

echo "PORT=$NEXT_PORT" >>"$WORKSPACE_PATH/.env"
echo "PLAYWRIGHT_MCP_PORT=$NEXT_PLAYWRIGHT_PORT" >>"$WORKSPACE_PATH/.env"
echo "MIX_DEV_PARTITION=$PARTITION" >>"$WORKSPACE_PATH/.env"
echo "MIX_TEST_PARTITION=$PARTITION" >>"$WORKSPACE_PATH/.env"

echo "⚙️  Setting up workspace (port: $NEXT_PORT, playwright: $NEXT_PLAYWRIGHT_PORT, partition: $PARTITION)..."

mkdir -p "$WORKSPACE_PATH/.vscode"

if [ -f "$SCRIPT_DIR/templates/.vscode/settings.json" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/settings.json" "$WORKSPACE_PATH/.vscode/"
    sed -i '' "s/4000/$NEXT_PORT/g" "$WORKSPACE_PATH/.vscode/settings.json"
fi

if [ -f "$SCRIPT_DIR/templates/.vscode/tasks.json" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/tasks.json" "$WORKSPACE_PATH/.vscode/"
fi

if [ -f "$SCRIPT_DIR/templates/feature-workspace.code-workspace" ]; then
    cp "$SCRIPT_DIR/templates/feature-workspace.code-workspace" "$WORKSPACE_PATH/${FEATURE_NAME}.code-workspace"
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

PLAN_TITLE="$FEATURE_NAME"

if [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" "$WORKSPACE_PATH/codegen/PLAN.md"

    PLAN_TITLE=$(head -n 1 "$WORKSPACE_PATH/codegen/PLAN.md" | sed 's/^# *//' | sed 's/ *$//')
    PLAN_TITLE=$(echo "$PLAN_TITLE" | sed 's/[[\.*^$()+?{|&]/\\&/g')
fi

if [ -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" "$WORKSPACE_PATH/codegen/PROJECT_CONTEXT.md"
fi

if [ -f "$SCRIPT_DIR/templates/CONTEXT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$SCRIPT_DIR/templates/CONTEXT.md" "$WORKSPACE_PATH/codegen/CONTEXT.md"

    sed -i '' "s|{{FEATURE_NAME}}|$FEATURE_NAME|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{PARTITION}}|$PARTITION|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{PLAN_TITLE}}|$PLAN_TITLE|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{PORT}}|$NEXT_PORT|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{DB_NAME_PREFIX}}|$DB_NAME_PREFIX|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
fi

if [ -f "$SCRIPT_DIR/templates/NEW_PROMPT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$SCRIPT_DIR/templates/NEW_PROMPT.md" "$WORKSPACE_PATH/codegen/PROMPT.md"

    sed -i '' "s|{{FEATURE_NAME}}|$FEATURE_NAME|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAN_TITLE}}|$PLAN_TITLE|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PORT}}|$NEXT_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAYWRIGHT_MCP_PORT}}|$NEXT_PLAYWRIGHT_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{WORKSPACE_PATH}}|$WORKSPACE_PATH|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
fi

# Link to rules directory from main branch (so changes propagate)
if [ -d "$REPO_ROOT/codegen/rules" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    ln -sf "$REPO_ROOT/codegen/rules" "$WORKSPACE_PATH/codegen/rules"
    echo "✅ Linked codegen/rules from main branch (changes will propagate)"
fi

# Copy CLAUDE.md from main branch since it's gitignored
if [ -f "$REPO_ROOT/CLAUDE.md" ]; then
    cp "$REPO_ROOT/CLAUDE.md" "$WORKSPACE_PATH/CLAUDE.md"
    echo "✅ Copied CLAUDE.md from main branch"
fi

# Create .mcp.json from template with port substitution
if [ -f "$SCRIPT_DIR/templates/.mcp.json" ]; then
    sed "s/{{PORT}}/${NEXT_PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${NEXT_PLAYWRIGHT_PORT}/g" \
        "$SCRIPT_DIR/templates/.mcp.json" >"$WORKSPACE_PATH/.mcp.json"
    echo "✅ Created .mcp.json with workspace-specific ports"
fi

# Copy ci.sh to workspace codegen directory for workspace-specific CI checks
mkdir -p "$WORKSPACE_PATH/codegen"
if [ -f "$SCRIPT_DIR/templates/ci.sh" ]; then
    cp "$SCRIPT_DIR/templates/ci.sh" "$WORKSPACE_PATH/codegen/ci.sh"
    chmod +x "$WORKSPACE_PATH/codegen/ci.sh"
    echo "✅ Copied ci.sh for workspace-specific CI checks"
fi

open_cursor_workspace "$WORKSPACE_PATH" "$FEATURE_NAME" "✅ Workspace created successfully!"

echo ""
echo "🎉 Workspace ready: $FEATURE_NAME"
echo "🔌 Port: $NEXT_PORT | 🎭 Playwright: $NEXT_PLAYWRIGHT_PORT | 🗄️ Partition: $PARTITION | 🌿 Branch: $BRANCH_NAME"
echo "🌐 Server will be available at: http://localhost:$NEXT_PORT"
echo "📁 $WORKSPACE_PATH"
if [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    echo "📋 Plan: codegen/plans/${FEATURE_NAME}.md"
fi
echo ""
echo "To remove: $OCG_CMD rm $FEATURE_NAME"
