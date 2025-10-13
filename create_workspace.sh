#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <feature-name> [options]"
    echo "Options:"
    echo "  --model, -m <model>      AI model to use (default: sonnet)"
    echo "  --agent, -a <name>   AI agent to use (default: from config)"
    echo "  --container              Run in Docker container"
    echo ""
    echo "Examples:"
    echo "  $0 dashboard-redesign"
    echo "  $0 dashboard-redesign --model opus"
    echo "  $0 dashboard-redesign --agent opencode"
    echo "  $0 dashboard-redesign -m opus -a opencode --container"
    exit 1
fi

# Parse arguments
CONTAINER_MODE=false
MODEL="sonnet" # Default model
AGENT=""       # Will use default from config if not specified
FEATURE_NAME=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --model | -m)
        MODEL="$2"
        shift 2
        ;;
    --agent | -a | --ai)
        AGENT="$2"
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
source "$SCRIPT_DIR/resource_manager.sh"

# Load default agent from config if not specified
if [ -z "$AGENT" ]; then
    CONFIG_FILE="$HOME/.ocg/config.json"
    if [ -f "$CONFIG_FILE" ]; then
        AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
    else
        echo "❌ No default AI agent configured. Run 'make install' to configure."
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

# Legacy functions for backward compatibility - now use global resource manager
get_next_port() {
    local port=$(allocate_phoenix_port "$REPO_NAME" "$WORKSPACE_NAME")
    if [ $? -eq 0 ] && [ -n "$port" ]; then
        echo "$port"
    else
        # Fallback to local scanning if global allocation fails
        fallback_get_next_phoenix_port
    fi
}

get_next_playwright_port() {
    local port=$(allocate_playwright_port "$REPO_NAME" "$WORKSPACE_NAME")
    if [ $? -eq 0 ] && [ -n "$port" ]; then
        echo "$port"
    else
        # Fallback to local scanning if global allocation fails
        fallback_get_next_playwright_port
    fi
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

# Copy the universal AI agent script
if [ -f "$SCRIPT_DIR/templates/.vscode/ai-agent.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/ai-agent.sh" "$WORKSPACE_PATH/.vscode/ai-agent.sh"
    chmod +x "$WORKSPACE_PATH/.vscode/ai-agent.sh"
fi

# Pass model and agent through environment variables to startup script
export AI_AGENT="$AGENT"
export AI_MODEL="$MODEL"

# For backward compatibility, create claude-code.sh as a symlink
ln -sf "ai-agent.sh" "$WORKSPACE_PATH/.vscode/claude-code.sh"

if [ -f "$SCRIPT_DIR/templates/.vscode/phoenix-server.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/phoenix-server.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/phoenix-server.sh"
fi

PLAN_TITLE="$FEATURE_NAME"

# Copy plan structure
if [ -d "$REPO_ROOT/codegen/plans/${FEATURE_NAME}" ]; then
    # Modular plan structure
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp -r "$REPO_ROOT/codegen/plans/${FEATURE_NAME}" "$WORKSPACE_PATH/codegen/plan"
elif [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    # Single file plan - save as overview
    mkdir -p "$WORKSPACE_PATH/codegen/plan"
    cp "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" "$WORKSPACE_PATH/codegen/plan/overview.md"
fi

# Extract plan title for templates
if [ -f "$WORKSPACE_PATH/codegen/plan/overview.md" ]; then
    PLAN_TITLE=$(head -n 1 "$WORKSPACE_PATH/codegen/plan/overview.md" | sed 's/^# *//' | sed 's/ *$//')
    PLAN_TITLE=$(echo "$PLAN_TITLE" | sed 's/[[\.*^$()+?{|&]/\\&/g')
fi

if [ -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" "$WORKSPACE_PATH/codegen/PROJECT_CONTEXT.md"
fi

# Copy Figma files only if they exist in the main repository (project-specific)
for figma_file in "FIGMA_MAP.md" "FIGMA_DESIGN_SYSTEM_RULES.md" "FIGMA_TOKEN_MAPPING.md"; do
    mkdir -p "$WORKSPACE_PATH/codegen"

    if [ -f "$REPO_ROOT/codegen/$figma_file" ]; then
        # Copy from main repo (project-specific version)
        cp "$REPO_ROOT/codegen/$figma_file" "$WORKSPACE_PATH/codegen/$figma_file"
        echo "✅ Copied $figma_file from main repository"
    else
        echo "ℹ️  $figma_file not found in main repo - skipping (project doesn't use Figma)"
    fi
done

if [ -f "$SCRIPT_DIR/templates/CONTEXT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$SCRIPT_DIR/templates/CONTEXT.md" "$WORKSPACE_PATH/codegen/CONTEXT.md"

    sed -i '' "s|{{FEATURE_NAME}}|$FEATURE_NAME|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{PARTITION}}|$PARTITION|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{PLAN_TITLE}}|$PLAN_TITLE|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{PORT}}|$NEXT_PORT|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{DB_NAME_PREFIX}}|$DB_NAME_PREFIX|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"
    sed -i '' "s|{{WORKSPACE_PATH}}|$WORKSPACE_PATH|g" "$WORKSPACE_PATH/codegen/CONTEXT.md"

    # Initialize modular context structure
    mkdir -p "$WORKSPACE_PATH/codegen/context"
    echo "# Step Context Files" >"$WORKSPACE_PATH/codegen/context/README.md"
    echo "" >>"$WORKSPACE_PATH/codegen/context/README.md"
    echo "This directory contains detailed progress and lessons for each implementation step." >>"$WORKSPACE_PATH/codegen/context/README.md"
    echo "Files are created as you work on each step to preserve implementation details." >>"$WORKSPACE_PATH/codegen/context/README.md"
fi

if [ -f "$SCRIPT_DIR/templates/NEW_PROMPT.md" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp "$SCRIPT_DIR/templates/NEW_PROMPT.md" "$WORKSPACE_PATH/codegen/PROMPT.md"

    sed -i '' "s|{{FEATURE_NAME}}|$FEATURE_NAME|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAN_TITLE}}|$PLAN_TITLE|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PORT}}|$NEXT_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"
    sed -i '' "s|{{PLAYWRIGHT_MCP_PORT}}|$NEXT_PLAYWRIGHT_PORT|g" "$WORKSPACE_PATH/codegen/PROMPT.md"

    # Set the correct agent context file based on AI agent
    if [ "$AGENT" = "opencode" ]; then
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

# Create symlink to recipes for subagent recipe discovery
if [ -d "$REPO_ROOT/codegen/recipes" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    ln -sf "$REPO_ROOT/codegen/recipes" "$WORKSPACE_PATH/codegen/recipes"
    echo "✅ Linked codegen/recipes from main branch (recipe discovery enabled)"
fi

# Copy AGENTS.md from main branch since it's gitignored
if [ -f "$REPO_ROOT/AGENTS.md" ]; then
    cp "$REPO_ROOT/AGENTS.md" "$WORKSPACE_PATH/AGENTS.md"
    echo "✅ Copied AGENTS.md from main branch"
fi

# Create CLAUDE.md symlink for backward compatibility (in workspace root)
ln -sf "AGENTS.md" "$WORKSPACE_PATH/CLAUDE.md"
echo "✅ Created CLAUDE.md symlink for backward compatibility"

# Create MCP configuration based on agent
if [ "$AGENT" = "opencode" ]; then
    # Create OpenCode MCP configuration in workspace root
    if [ -f "$SCRIPT_DIR/templates/.opencode-mcp.json" ]; then
        sed "s/{{PORT}}/${NEXT_PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${NEXT_PLAYWRIGHT_PORT}/g" \
            "$SCRIPT_DIR/templates/.opencode-mcp.json" >"$WORKSPACE_PATH/opencode.json"
        echo "✅ Created opencode.json with MCP configuration and workspace-specific ports"
    fi
elif [ "$AGENT" = "cursor" ]; then
    # Create Cursor MCP configuration (mcp.json, not .mcp.json)
    if [ -f "$SCRIPT_DIR/templates/.mcp.json" ]; then
        sed "s/{{PORT}}/${NEXT_PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${NEXT_PLAYWRIGHT_PORT}/g" \
            "$SCRIPT_DIR/templates/.mcp.json" >"$WORKSPACE_PATH/mcp.json"
        echo "✅ Created mcp.json with workspace-specific ports for Cursor"
    fi
    # Cursor reads AGENTS.md from workspace root (already copied from templates/AGENTS.md above)
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

    # Ensure shared AI agent volumes exist
    ensure_shared_ai_volumes

    # Clone volumes for workspace
    clone_deps_volumes "$FEATURE_NAME" "$REPO_NAME"

    # Export AI agent for docker-compose template
    export AI_AGENT="$AGENT"

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
if [ -d "$REPO_ROOT/codegen/plans/${FEATURE_NAME}" ]; then
    echo "📋 Plan: codegen/plan/ (modular structure)"
elif [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    echo "📋 Plan: codegen/plans/${FEATURE_NAME}.md"
fi
echo ""
echo "To remove: $OCG_CMD rm $FEATURE_NAME"
