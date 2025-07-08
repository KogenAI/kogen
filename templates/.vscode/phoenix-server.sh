#!/bin/bash
# Phoenix server startup script

WORKSPACE_ROOT="$(pwd)"
FEATURE_NAME="$(basename "$WORKSPACE_ROOT")"
PROJECT_ROOT="$(cd "$WORKSPACE_ROOT/../../.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
CONTAINER_NAME="ocg-${PROJECT_NAME}-${FEATURE_NAME}"

# Source version detection for this project
source "$WORKSPACE_ROOT/codegen/detect_versions.sh"
detect_versions "$PROJECT_ROOT"
export_versions

# Load environment variables from .env file
if [ -f "$WORKSPACE_ROOT/.env" ]; then
    export $(cat "$WORKSPACE_ROOT/.env" | grep -v '^#' | xargs)
fi

echo "🚀 Starting Phoenix server for workspace: $FEATURE_NAME"
echo "================================================"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ Docker container is not running!"
    echo "   Please start the workspace first using the 'Startup' task"
    exit 1
fi

# Start the Phoenix server
echo "🔌 Starting server on port ${PORT:-4000}..."
echo ""
docker exec -it --user ubuntu --workdir /workspace "${CONTAINER_NAME}" bash -c "
    export PATH='/home/ubuntu/.elixir-install/installs/elixir/1.18.4-otp-27/bin:/home/ubuntu/.elixir-install/installs/otp/27.3.4/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    export HOME='/home/ubuntu'
    
    # Load environment variables
    if [ -f .env ]; then
        export \$(cat .env | grep -v '^#' | xargs)
    fi
    
    # Start the server using detected version path
    $MIX_PATH phx.server
"
