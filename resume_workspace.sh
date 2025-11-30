#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <feature-name> [options]"
    echo "Options:"
    echo "  --model, -m <model>      AI model to use (default: from workspace)"
    echo "  --agent, -a <name>   AI agent to use (default: from workspace)"
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
MODEL="" # Will use workspace default if not specified
AGENT="" # Will use workspace default if not specified
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

# Simple configuration loading:
# 1. Use command line flags if provided
# 2. Otherwise use global defaults

# Set defaults
if [ -z "$MODEL" ]; then
    MODEL="sonnet"
fi

if [ -z "$AGENT" ]; then
    # Load from global config
    CONFIG_FILE="$HOME/.ocg/config.json"
    if [ -f "$CONFIG_FILE" ]; then
        AGENT=$(jq -r '.default_agent // "claude"' "$CONFIG_FILE")
    else
        AGENT="claude"
    fi
fi

echo "🔍 Using AI agent: $AGENT with model: $MODEL"

# Pass through environment variables
export AI_AGENT="$AGENT"
export AI_MODEL="$MODEL"

cd "$WORKSPACE_PATH"

git submodule update --init --recursive >/dev/null 2>&1

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null | cut -c1-8 || echo "unknown")

if [ -f "$WORKSPACE_PATH/.env" ]; then
    # Use tail -1 to get last occurrence (workspace overrides template defaults)
    PORT=$(grep "^PORT=" "$WORKSPACE_PATH/.env" 2>/dev/null | tail -1 | cut -d'=' -f2)
    PARTITION=$(grep "^MIX_DEV_PARTITION=" "$WORKSPACE_PATH/.env" 2>/dev/null | tail -1 | cut -d'=' -f2)
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
        # Use tail -1 to get last occurrence (workspace overrides template defaults)
        WORKSPACE_PORT=$(grep "^PORT=" "$WORKSPACE_PATH/.env" 2>/dev/null | tail -1 | cut -d'=' -f2)
        if [ -n "$WORKSPACE_PORT" ]; then
            sed -i '' "s/4000/$WORKSPACE_PORT/g" "$WORKSPACE_PATH/.vscode/settings.json"
        fi
    fi
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

# For backward compatibility, create claude-code.sh as a symlink
ln -sf "ai-agent.sh" "$WORKSPACE_PATH/.vscode/claude-code.sh"

if [ -f "$SCRIPT_DIR/templates/.vscode/phoenix-server.sh" ]; then
    cp "$SCRIPT_DIR/templates/.vscode/phoenix-server.sh" "$WORKSPACE_PATH/.vscode/"
    chmod +x "$WORKSPACE_PATH/.vscode/phoenix-server.sh"
fi

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

# Update plan structure
if [ -d "$REPO_ROOT/codegen/plans/${FEATURE_NAME}" ]; then
    # Modular plan structure
    rm -rf "$WORKSPACE_PATH/codegen/plan" 2>/dev/null || true
    mkdir -p "$WORKSPACE_PATH/codegen"
    cp -r "$REPO_ROOT/codegen/plans/${FEATURE_NAME}" "$WORKSPACE_PATH/codegen/plan"
elif [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    # Single file plan - save as overview
    rm -rf "$WORKSPACE_PATH/codegen/plan" 2>/dev/null || true
    mkdir -p "$WORKSPACE_PATH/codegen/plan"
    cp "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" "$WORKSPACE_PATH/codegen/plan/overview.md"
fi

if [ -f "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" ]; then
    cp "$REPO_ROOT/codegen/PROJECT_CONTEXT.md" "$WORKSPACE_PATH/codegen/PROJECT_CONTEXT.md"
fi

# Copy Figma files only if they exist in the main repository (project-specific)
for figma_file in "FIGMA_MAP.md" "FIGMA_DESIGN_SYSTEM_RULES.md" "FIGMA_TOKEN_MAPPING.md"; do
    if [ -f "$REPO_ROOT/codegen/$figma_file" ]; then
        # Copy from main repo (project-specific version)
        cp "$REPO_ROOT/codegen/$figma_file" "$WORKSPACE_PATH/codegen/$figma_file"
        echo "✅ Copied $figma_file from main repository"
    else
        echo "ℹ️  $figma_file not found in main repo - skipping (project doesn't use Figma)"
    fi
done

# Link to rules directory from main branch (so changes propagate)
if [ -d "$REPO_ROOT/codegen/rules" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    # Remove existing rules directory if it exists
    [ -d "$WORKSPACE_PATH/codegen/rules" ] && rm -rf "$WORKSPACE_PATH/codegen/rules"
    ln -sf "$REPO_ROOT/codegen/rules" "$WORKSPACE_PATH/codegen/rules"
    echo "✅ Linked codegen/rules from main branch (changes will propagate)"
fi

# Create symlink to recipes for subagent recipe discovery
if [ -d "$REPO_ROOT/codegen/recipes" ]; then
    mkdir -p "$WORKSPACE_PATH/codegen"
    # Remove existing recipes directory if it exists
    [ -d "$WORKSPACE_PATH/codegen/recipes" ] && rm -rf "$WORKSPACE_PATH/codegen/recipes"
    ln -sf "$REPO_ROOT/codegen/recipes" "$WORKSPACE_PATH/codegen/recipes"
    echo "✅ Linked codegen/recipes from main branch (recipe discovery enabled)"
fi

# Copy AGENTS.md from main branch since it's gitignored
if [ -f "$REPO_ROOT/AGENTS.md" ]; then
    cp "$REPO_ROOT/AGENTS.md" "$WORKSPACE_PATH/AGENTS.md"
    echo "✅ Copied AGENTS.md from main branch"
fi

# Create or update CLAUDE.md symlink for backward compatibility
if [ -e "$WORKSPACE_PATH/CLAUDE.md" ]; then
    rm -f "$WORKSPACE_PATH/CLAUDE.md"
fi
ln -sf "AGENTS.md" "$WORKSPACE_PATH/CLAUDE.md"
echo "✅ Created CLAUDE.md symlink for backward compatibility"

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

# Update MCP configuration if needed
if [ "$AGENT" = "opencode" ]; then
    # Update OpenCode MCP configuration with current ports
    if [ -f "$SCRIPT_DIR/templates/.opencode-mcp.json" ] && [ -n "$PORT" ] && [ -n "$PLAYWRIGHT_MCP_PORT" ]; then
        sed "s/{{PORT}}/${PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${PLAYWRIGHT_MCP_PORT}/g" \
            "$SCRIPT_DIR/templates/.opencode-mcp.json" >"$WORKSPACE_PATH/opencode.json"
        echo "✅ Updated opencode.json with current workspace ports"
    fi
else
    # Update Claude MCP configuration with current ports
    if [ -f "$SCRIPT_DIR/templates/.mcp.json" ] && [ -n "$PORT" ] && [ -n "$PLAYWRIGHT_MCP_PORT" ]; then
        sed "s/{{PORT}}/${PORT}/g; s/{{PLAYWRIGHT_MCP_PORT}}/${PLAYWRIGHT_MCP_PORT}/g" \
            "$SCRIPT_DIR/templates/.mcp.json" >"$WORKSPACE_PATH/.mcp.json"
        echo "✅ Updated .mcp.json with current workspace ports"
    fi
fi

# Resume workspace - either in container or native
if [ "$CONTAINER_MODE" = true ]; then
    echo "🐳 Resuming container workspace..."

    # Define REPO_NAME for container operations
    REPO_NAME="$(basename "$REPO_ROOT")"

    # Source docker utilities
    source "$SCRIPT_DIR/docker_utils.sh"

    # Check Docker is available
    if ! check_docker; then
        exit 1
    fi

    # Ensure shared Claude volume exists
    ensure_shared_claude_volume

    # Clone volumes for workspace if they don't exist
    clone_deps_volumes "$FEATURE_NAME" "$REPO_NAME"

    # Create docker-compose.yml if it doesn't exist
    if [ ! -f "$WORKSPACE_PATH/docker-compose.yml" ]; then
        create_docker_compose "$WORKSPACE_PATH" "$FEATURE_NAME" "$SCRIPT_DIR/dockerfiles/docker-compose.yml.template" "$REPO_NAME"
    fi

    # Start existing container or recreate if needed
    start_docker_workspace "$WORKSPACE_PATH" "$FEATURE_NAME"

    echo "✅ Container workspace resumed successfully!"
    echo "🐳 Container: ocg-$REPO_NAME-$FEATURE_NAME"
    echo "💡 To access container: docker exec -it ocg-$REPO_NAME-$FEATURE_NAME /bin/bash"

    # Open Cursor for container workspace
    open_cursor_workspace "$WORKSPACE_PATH" "$FEATURE_NAME" "✅ Container workspace resumed!"
else
    # Check if this is a monorepo with Flutter - ensure API_URL is configured
    if [ -d "$WORKSPACE_PATH/mobile" ]; then
        # Ensure API_URL is in .env (idempotent - won't duplicate)
        if [ "$PORT" != "not configured" ] && ! grep -q "^API_URL=" "$WORKSPACE_PATH/.env" 2>/dev/null; then
            echo "API_URL=http://localhost:$PORT" >>"$WORKSPACE_PATH/.env"
            echo "✅ Added API_URL to .env (port $PORT)"
        fi
        # Flutter dependencies are installed in the startup script inside the workspace
    fi

    open_cursor_workspace "$WORKSPACE_PATH" "$FEATURE_NAME" "✅ Workspace resumed successfully!"
fi

echo ""
echo "🎯 Workspace resumed: $FEATURE_NAME"
if [ -n "$PORT" ] && [ "$PORT" != "not configured" ] && [ -n "$PLAYWRIGHT_MCP_PORT" ] && [ -n "$PARTITION" ]; then
    echo "🔌 Port: $PORT | 🎭 Playwright: $PLAYWRIGHT_MCP_PORT | 🗄️ Partition: $PARTITION | 🌿 Branch: $CURRENT_BRANCH"
fi
if [ -n "$PORT" ] && [ "$PORT" != "not configured" ]; then
    echo "🌐 Server will be available at: http://localhost:$PORT"
fi
echo "📁 $WORKSPACE_PATH"
if [ -d "$REPO_ROOT/codegen/plans/${FEATURE_NAME}" ]; then
    echo "📋 Plan: codegen/plan/ (modular structure)"
elif [ -f "$REPO_ROOT/codegen/plans/${FEATURE_NAME}.md" ]; then
    echo "📋 Plan: codegen/plans/${FEATURE_NAME}.md"
fi
echo ""
echo "To remove: $OCG_CMD rm $FEATURE_NAME"
