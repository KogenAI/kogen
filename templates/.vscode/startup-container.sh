#!/bin/bash
set -e

echo "🚀 Initializing Docker workspace environment..."

WORKSPACE_ROOT="$(pwd)"
FEATURE_NAME="$(basename "$WORKSPACE_ROOT")"
# Get project name from parent directories (go up from workspace to project root)
PROJECT_ROOT="$(cd "$WORKSPACE_ROOT/../../.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

# Cleanup function to stop Docker container on exit
cleanup() {
    echo ""
    echo "🛑 Shutting down Docker container..."
    if docker ps --format '{{.Names}}' | grep -q "^ocg-${PROJECT_NAME}-${FEATURE_NAME}$"; then
        docker compose down
        echo "✅ Docker container stopped"
    fi
    echo "👋 Goodbye!"
}

# Register cleanup function to run on script exit
trap cleanup EXIT INT TERM

# Docker files are now copied to the workspace's codegen directory
WORKSPACE_CODEGEN_DIR="$WORKSPACE_ROOT/codegen"

# Set SCRIPT_DIR for docker_utils.sh functions
export SCRIPT_DIR="$WORKSPACE_CODEGEN_DIR"

# Source utilities from the workspace's codegen directory
source "$WORKSPACE_CODEGEN_DIR/docker_utils.sh"
source "$WORKSPACE_CODEGEN_DIR/config.sh"

# Load environment variables
if [ -f ".env" ]; then
    export $(cat .env | grep -v '^#' | xargs)
    # Set PARTITION for docker-compose template substitution
    export PARTITION="$MIX_DEV_PARTITION"
fi

# Create wait files to block tasks until ready
mkdir -p codegen
touch codegen/.ai_wait
echo "🔒 Created wait files - tasks will wait for signals"

# Check Docker is available
echo "🐳 Checking Docker environment..."
if ! check_docker; then
    echo "❌ Docker is required but not available. Please install Docker Desktop."
    echo "   Visit: https://www.docker.com/products/docker-desktop"
    exit 1
fi

# Ensure Docker image exists (DOCKER_IMAGE comes from config.sh)
if ! docker images | grep -q "ocg/phoenix"; then
    echo "🔨 Building base Docker image: $DOCKER_IMAGE"
    echo "   This will use cache if available..."
    if ! build_base_image "$WORKSPACE_CODEGEN_DIR/dockerfiles/Dockerfile.phoenix" "$PROJECT_ROOT"; then
        echo "❌ Failed to build Docker image"
        exit 1
    fi
    echo "✅ Docker image ready: $DOCKER_IMAGE"
else
    echo "✅ Docker image found: $DOCKER_IMAGE"
fi

# Clone dependencies volumes for this workspace
clone_deps_volumes "$FEATURE_NAME" "$PROJECT_NAME"

# Fix Claude auth permissions
fix_claude_auth_permissions "$PROJECT_NAME"

# Create docker-compose.yml if it doesn't exist
if [ ! -f "docker-compose.yml" ]; then
    echo "📝 Creating Docker configuration..."
    # Create docker-compose.yml from template
    create_docker_compose "$WORKSPACE_ROOT" "$FEATURE_NAME" "$WORKSPACE_CODEGEN_DIR/dockerfiles/docker-compose.yml.template" "$PROJECT_NAME"
fi

# Always ensure container startup script exists
if [ ! -f "codegen/startup.sh" ]; then
    echo "📝 Creating container startup script..."
    setup_container_startup "$WORKSPACE_ROOT"
fi

prepare_context() {
    local mode="$1"

    prompt_file="codegen/PROMPT.md"
    if [ ! -f "$prompt_file" ]; then
        return 1
    fi

    if [ "$mode" = "resume" ]; then
        # Get git status and commit log from inside container
        local git_status commit_log

        # Check if container is running first
        if docker ps --format '{{.Names}}' | grep -q "^ocg-${PROJECT_NAME}-${FEATURE_NAME}$"; then
            git_status=$(docker exec "ocg-${PROJECT_NAME}-${FEATURE_NAME}" git status --porcelain 2>/dev/null || echo "# Unable to get git status")

            if docker exec "ocg-${PROJECT_NAME}-${FEATURE_NAME}" git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
                commit_count=$(docker exec "ocg-${PROJECT_NAME}-${FEATURE_NAME}" git rev-list --count main..HEAD 2>/dev/null || echo "0")
                if [ "$commit_count" -gt 0 ]; then
                    commit_log=$(docker exec "ocg-${PROJECT_NAME}-${FEATURE_NAME}" git log --oneline main..HEAD 2>/dev/null || echo "# Unable to get commit log")
                else
                    commit_log="# No commits ahead of main branch"
                fi
            else
                commit_log="# Main branch not found"
            fi
        else
            # Fallback to local git if container not running yet
            git_status=$(git status --porcelain 2>/dev/null || echo "# Unable to get git status")

            if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
                commit_count=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
                if [ "$commit_count" -gt 0 ]; then
                    commit_log=$(git log --oneline main..HEAD 2>/dev/null || echo "# Unable to get commit log")
                else
                    commit_log="# No commits ahead of main branch"
                fi
            else
                commit_log="# Main branch not found"
            fi
        fi

        local context=$(cat "$prompt_file")
        context="${context//\{\{GIT_STATUS\}\}/$git_status}"
        context="${context//\{\{COMMIT_LOG\}\}/$commit_log}"

        echo "$context" >"$prompt_file"
    fi
}

setup_automation() {
    local mode="$1"

    if ! prepare_context "$mode"; then
        echo "❌ Failed to prepare context file"
        return 1
    fi

    echo "✅ Context prepared for Claude Code"

    if [ -f ".mcp.json" ]; then
        echo "✅ MCP configuration ready (.mcp.json found)"
    fi

    return 0
}

# Determine workspace mode
if [ -f ".ocg_resume" ]; then
    WORKSPACE_MODE="resume"
    echo "🔄 Resume mode detected"
    rm ".ocg_resume" # Clean up flag file
else
    WORKSPACE_MODE="new"
    echo "🆕 New workspace mode"
fi

# Start Docker container
echo "🐳 Starting Docker container..."
if ! start_docker_workspace "$WORKSPACE_ROOT" "$FEATURE_NAME"; then
    echo "❌ Failed to start Docker container"
    exit 1
fi

echo "✅ Docker container started"

# Run initial setup in container if new workspace
if [ "$WORKSPACE_MODE" = "new" ]; then
    echo "📦 Running initial setup in container..."
    # Don't suppress errors - we need to see what's happening
    exec_in_container "$FEATURE_NAME" "/workspace/codegen/startup.sh"
    echo "✅ Initial setup complete"
fi

setup_automation "$WORKSPACE_MODE"

show_workspace_summary() {
    echo ""
    echo "🎯 Docker workspace '$FEATURE_NAME' is ready!"
    echo "=================================="
    echo "🐳 Container: ocg-${PROJECT_NAME}-${FEATURE_NAME}"
    echo "🔌 Port: ${PORT:-4000}"
    echo "🗄️  Database: ${DB_NAME_PREFIX}_dev${MIX_DEV_PARTITION:-0}"
    echo "🌐 Server: http://localhost:${PORT:-4000}"
    echo "=================================="
    echo ""
    echo "📝 Commands:"
    echo "   Terminal: docker exec -it ocg-${PROJECT_NAME}-${FEATURE_NAME} /bin/bash"
    echo "   Phoenix:  docker exec -it ocg-${PROJECT_NAME}-${FEATURE_NAME} mix phx.server"
    echo "   Claude:   Run the Claude Code task in your editor"
    echo ""
}

show_workspace_summary

# Wait for container initialization to complete before releasing Claude Code
echo "⏳ Waiting for container initialization to complete..."
MAX_WAIT=60 # Maximum 60 seconds
WAIT_COUNT=0
while true; do
    if docker exec "ocg-${PROJECT_NAME}-${FEATURE_NAME}" test -f /workspace/codegen/.startup_complete 2>/dev/null; then
        echo "✅ Container initialization complete"
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 2))
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "⚠️  Timeout waiting for container initialization after ${MAX_WAIT} seconds"
        break
    fi
    echo "   Still waiting... ($WAIT_COUNT/$MAX_WAIT seconds)"
    sleep 2
done

# Release AI agent to start (if waiting)
echo "🔓 Releasing AI agent to start..."
if [ -f codegen/.ai_wait ]; then
    rm -f codegen/.ai_wait
    echo "   ✅ Removed .ai_wait file"
else
    echo "   ℹ️  .ai_wait file was already removed"
fi

echo ""
echo "✅ Workspace initialization complete!"
echo "💡 All development happens inside the Docker container"
echo "📝 Use the terminal commands shown above to access the container"
echo ""
echo "⚠️  Keep this terminal open to keep the Docker container running"
echo "   Closing this terminal will stop the container"

# Keep the script running
echo ""
echo "Press Ctrl+C to stop the container and exit..."
while true; do
    sleep 1
done
