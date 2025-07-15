#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <feature-name> [options]"
    echo "Options:"
    echo "  --model, -m <model>      AI model to use (default: sonnet)"
    echo "  --assistant, -a <name>   AI assistant to use (default: from config)"
    echo "  --container              Run in Docker container"
    echo ""
    echo "Examples:"
    echo "  $0 dashboard-redesign"
    echo "  $0 dashboard-redesign --model opus"
    echo "  $0 dashboard-redesign --assistant opencode"
    echo "  $0 dashboard-redesign -m opus -a opencode --container"
    exit 1
fi

# Parse arguments
CONTAINER_MODE=false
MODEL="sonnet" # Default model
ASSISTANT=""   # Will use default from config if not specified
FEATURE_NAME=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --model | -m)
        MODEL="$2"
        shift 2
        ;;
    --assistant | -a | --ai)
        ASSISTANT="$2"
        shift 2
        ;;
    --container)
        CONTAINER_MODE=true
        shift
        ;;
    -*)
        echo "Unknown option: $1"
        exit 1
        ;;
    *)
        if [ -z "$FEATURE_NAME" ]; then
            FEATURE_NAME="$1"
        fi
        shift
        ;;
    esac
done

if [ -z "$FEATURE_NAME" ]; then
    echo "Error: Feature name is required"
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

# Load default assistant from config if not specified
if [ -z "$ASSISTANT" ]; then
    CONFIG_FILE="$HOME/.ocg/config.json"
    if [ -f "$CONFIG_FILE" ]; then
        ASSISTANT=$(jq -r '.default_assistant // "claude"' "$CONFIG_FILE")
    else
        echo "❌ No default AI assistant configured. Run 'make install' to configure."
        exit 1
    fi
fi

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
PORT_TEST=$((NEXT_PORT + 100))

if [ -f "$REPO_ROOT/.env" ]; then
    cp "$REPO_ROOT/.env" "$WORKSPACE_PATH/.env"
    echo "" >>"$WORKSPACE_PATH/.env"
fi

echo "PORT=$NEXT_PORT" >>"$WORKSPACE_PATH/.env"
echo "PORT_TEST=$PORT_TEST" >>"$WORKSPACE_PATH/.env"
echo "PLAYWRIGHT_MCP_PORT=$NEXT_PLAYWRIGHT_PORT" >>"$WORKSPACE_PATH/.env"
echo "MIX_DEV_PARTITION=$PARTITION" >>"$WORKSPACE_PATH/.env"
echo "MIX_TEST_PARTITION=$PARTITION" >>"$WORKSPACE_PATH/.env"

echo "⚙️  Setting up workspace (port: $NEXT_PORT, test_port: $PORT_TEST, playwright: $NEXT_PLAYWRIGHT_PORT, partition: $PARTITION)..."

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

# Copy appropriate startup script based on container mode
if [ "$CONTAINER_MODE" = true ]; then
    STARTUP_TEMPLATE="$SCRIPT_DIR/templates/.vscode/startup-container.sh"
else
    STARTUP_TEMPLATE="$SCRIPT_DIR/templates/.vscode/startup-native.sh"
fi

if [ -f "$STARTUP_TEMPLATE" ]; then
    cp "$STARTUP_TEMPLATE" "$WORKSPACE_PATH/.vscode/startup.sh"
    chmod +x "$WORKSPACE_PATH/.vscode/startup.sh"
    sed -i '' "s/{{MODEL}}/$MODEL/g" "$WORKSPACE_PATH/.vscode/startup.sh"
    sed -i '' "s|{{DB_NAME_PREFIX}}|$DB_NAME_PREFIX|g" "$WORKSPACE_PATH/.vscode/startup.sh"
fi

if [ -f "$SCRIPT_DIR/templates/.vscode/workspace-info.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/workspace-info.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/workspace-info.sh"
fi

# Copy the universal AI assistant script
if [ -f "$SCRIPT_DIR/templates/.vscode/ai-assistant.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/ai-assistant.sh" "$WORKSPACE_PATH/.vscode/ai-assistant.sh"
    chmod +x "$WORKSPACE_PATH/.vscode/ai-assistant.sh"
fi

# Pass model and assistant through environment variables to startup script
export AI_ASSISTANT="$ASSISTANT"
export AI_MODEL="$MODEL"

# For backward compatibility, create claude-code.sh as a symlink
ln -sf "ai-assistant.sh" "$WORKSPACE_PATH/.vscode/claude-code.sh"

if [ -f "$SCRIPT_DIR/templates/.vscode/phoenix-server.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/phoenix-server.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/phoenix-server.sh"
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
    sed -i '' "s|{{WORKSPACE_PATH}}|$WORKSPACE_PATH|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
fi

if [ -f "$SCRIPT_DIR/templates/NEW_PROMPT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$SCRIPT_DIR/templates/NEW_PROMPT.md" "$WORKSPACE_PATH/codegen/PROMPT.md"

    sed -i '' "s|{{FEATURE_NAME}}|$FEATURE_NAME|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAN_TITLE}}|$PLAN_TITLE|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PORT}}|$NEXT_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAYWRIGHT_MCP_PORT}}|$NEXT_PLAYWRIGHT_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"

    # Set the correct agent context file based on AI assistant
    if [ "$ASSISTANT" = "opencode" ]; then
        sed -i '' "s|{{AGENT_CONTEXT_FILE}}|AGENTS.md|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    else
        sed -i '' "s|{{AGENT_CONTEXT_FILE}}|CLAUDE.md|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    fi

    # Use container path if in container mode, otherwise use host path
    if [ "$CONTAINER_MODE" = true ]; then
        sed -i '' "s|{{WORKSPACE_PATH}}|/workspace|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    else
        sed -i '' "s|{{WORKSPACE_PATH}}|$WORKSPACE_PATH|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    fi
fi

# Link to rules directory from main branch (so changes propagate)
if [ -d "$REPO_ROOT/codegen/rules" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    ln -sf "$REPO_ROOT/codegen/rules" "$WORKSPACE_PATH/codegen/rules"
    echo "✅ Linked codegen/rules from main branch (changes will propagate)"
fi

# Copy AGENTS.md from main branch since it's gitignored
if [ -f "$REPO_ROOT/AGENTS.md" ]; then
    cp "$REPO_ROOT/AGENTS.md" "$WORKSPACE_PATH/AGENTS.md"
    echo "✅ Copied AGENTS.md from main branch"
fi

# Create CLAUDE.md symlink for backward compatibility (in workspace root)
ln -sf "AGENTS.md" "$WORKSPACE_PATH/CLAUDE.md"
echo "✅ Created CLAUDE.md symlink for backward compatibility"

# Create MCP configuration based on assistant
if [ "$ASSISTANT" = "opencode" ]; then
    # Create OpenCode MCP configuration in workspace root
    if [ -f "$SCRIPT_DIR/templates/.opencode-mcp.json" ]; then
        sed "s/{{PORT}}/${NEXT_PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${NEXT_PLAYWRIGHT_PORT}/g" \
            "$SCRIPT_DIR/templates/.opencode-mcp.json" >"$WORKSPACE_PATH/opencode.json"
        echo "✅ Created opencode.json with MCP configuration and workspace-specific ports"
    fi
else
    # Create Claude MCP configuration
    if [ -f "$SCRIPT_DIR/templates/.mcp.json" ]; then
        sed "s/{{PORT}}/${NEXT_PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${NEXT_PLAYWRIGHT_PORT}/g" \
            "$SCRIPT_DIR/templates/.mcp.json" >"$WORKSPACE_PATH/.mcp.json"
        echo "✅ Created .mcp.json with workspace-specific ports"
    fi
fi

# Copy ci.sh to workspace codegen directory for workspace-specific CI checks
mkdir -p "$WORKSPACE_PATH/codegen"
if [ -f "$SCRIPT_DIR/templates/ci.sh" ]; then
    cp "$SCRIPT_DIR/templates/ci.sh" "$WORKSPACE_PATH/codegen/ci.sh"
    chmod +x "$WORKSPACE_PATH/codegen/ci.sh"
    echo "✅ Copied ci.sh for workspace-specific CI checks"
fi

# Copy Docker utilities and files to workspace
if [ -f "$SCRIPT_DIR/docker_utils.sh" ]; then
    cp "$SCRIPT_DIR/docker_utils.sh" "$WORKSPACE_PATH/codegen/docker_utils.sh"
    chmod +x "$WORKSPACE_PATH/codegen/docker_utils.sh"
    echo "✅ Copied docker_utils.sh to workspace"
fi

if [ -d "$SCRIPT_DIR/dockerfiles" ]; then
    cp -r "$SCRIPT_DIR/dockerfiles" "$WORKSPACE_PATH/codegen/"
    echo "✅ Copied dockerfiles directory to workspace"
fi

if [ -f "$SCRIPT_DIR/config.sh" ]; then
    cp "$SCRIPT_DIR/config.sh" "$WORKSPACE_PATH/codegen/config.sh"
    echo "✅ Copied config.sh to workspace"
fi

if [ -f "$SCRIPT_DIR/detect_versions.sh" ]; then
    cp "$SCRIPT_DIR/detect_versions.sh" "$WORKSPACE_PATH/codegen/detect_versions.sh"
    chmod +x "$WORKSPACE_PATH/codegen/detect_versions.sh"
    echo "✅ Copied detect_versions.sh to workspace"
fi

# Open workspace - either in container or native
if [ "$CONTAINER_MODE" = true ]; then
    echo "🐳 Setting up container workspace..."

    # Define REPO_NAME for container operations
    REPO_NAME="$(basename "$REPO_ROOT")"

    # Source docker utilities
    source "$SCRIPT_DIR/docker_utils.sh"

    # Check Docker is available
    if ! check_docker; then
        exit 1
    fi

    # Ensure shared AI assistant volumes exist
    ensure_shared_ai_volumes

    # Clone volumes for workspace
    clone_deps_volumes "$FEATURE_NAME" "$REPO_NAME"

    # Export AI assistant for docker-compose template
    export AI_ASSISTANT="$ASSISTANT"

    # Create and start container
    create_docker_compose "$WORKSPACE_PATH" "$FEATURE_NAME" "$SCRIPT_DIR/dockerfiles/docker-compose.yml.template" "$REPO_NAME"
    start_docker_workspace "$WORKSPACE_PATH" "$FEATURE_NAME"

    echo "✅ Container workspace created successfully!"
    echo "🐳 Container: ocg-$REPO_NAME-$FEATURE_NAME"
    echo "💡 To access container: docker exec -it ocg-$REPO_NAME-$FEATURE_NAME /bin/bash"

    # Open Cursor for container workspace
    open_cursor_workspace "$WORKSPACE_PATH" "$FEATURE_NAME" "✅ Container workspace created!"
else
    open_cursor_workspace "$WORKSPACE_PATH" "$FEATURE_NAME" "✅ Workspace created successfully!"
fi

echo ""
echo "🎉 Workspace ready: $FEATURE_NAME"
echo "🔌 Port: $NEXT_PORT | 🧪 Test Port: $PORT_TEST | 🎭 Playwright: $NEXT_PLAYWRIGHT_PORT | 🗄️ Partition: $PARTITION | 🌿 Branch: $BRANCH_NAME"
echo "🌐 Server will be available at: http://localhost:$NEXT_PORT"
echo "📁 $WORKSPACE_PATH"
if [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    echo "📋 Plan: codegen/plans/${FEATURE_NAME}.md"
fi
echo ""
echo "To remove: $OCG_CMD rm $FEATURE_NAME"
