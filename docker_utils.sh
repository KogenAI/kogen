#!/bin/bash

# Docker utility functions for OCG

# Source version detection
DOCKER_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DOCKER_UTILS_DIR/detect_versions.sh"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "❌ Docker is not installed or not in PATH"
        echo "   Please install Docker Desktop for Mac: https://www.docker.com/products/docker-desktop"
        return 1
    fi

    if ! docker info &>/dev/null; then
        echo "❌ Docker daemon is not running"
        echo "   Please start Docker Desktop"
        return 1
    fi

    return 0
}

# Ensure shared AI assistant volumes exist
ensure_shared_ai_volumes() {
    echo "🔐 Setting up shared AI assistant volumes..."

    # Create Claude shared volume
    if ! docker volume ls | grep -q "ocg-claude-shared"; then
        docker volume create "ocg-claude-shared" >/dev/null 2>&1
        echo "   ✅ Created shared Claude volume: ocg-claude-shared"
    else
        echo "   ✓ Shared Claude volume exists: ocg-claude-shared"
    fi

    # Create OpenCode shared volume
    if ! docker volume ls | grep -q "ocg-opencode-shared"; then
        docker volume create "ocg-opencode-shared" >/dev/null 2>&1
        echo "   ✅ Created shared OpenCode volume: ocg-opencode-shared"
    else
        echo "   ✓ Shared OpenCode volume exists: ocg-opencode-shared"
    fi

    # Create AI config shared volume
    if ! docker volume ls | grep -q "ocg-ai-config-shared"; then
        docker volume create "ocg-ai-config-shared" >/dev/null 2>&1
        echo "   ✅ Created shared AI config volume: ocg-ai-config-shared"
    else
        echo "   ✓ Shared AI config volume exists: ocg-ai-config-shared"
    fi
}

# Ensure shared Claude volume exists (backward compatibility)
ensure_shared_claude_volume() {
    ensure_shared_ai_volumes
}

# Clone volumes for workspace-specific use
# Fix Claude auth volume permissions
fix_claude_auth_permissions() {
    local project_name="$1"

    echo "🔧 Fixing Claude authentication permissions..."

    # Create the shared volume if it doesn't exist
    if ! docker volume ls | grep -q "ocg-claude-shared"; then
        docker volume create "ocg-claude-shared" >/dev/null 2>&1
        echo "   ✓ Created Claude shared volume"
    fi

    # Copy host Claude settings to shared volume if not present or outdated
    if [ -f "$HOME/.claude/settings.json" ]; then
        # Always copy settings.json to ensure it's up to date
        echo "   📋 Syncing Claude settings from host..."
        docker run --rm \
            -v "ocg-claude-shared":/claude \
            -v "$HOME/.claude":/host-claude:ro \
            --user root \
            alpine sh -c "
                # Copy settings.json and IDE settings (but preserve credentials if they exist)
                cp /host-claude/settings.json /claude/ 2>/dev/null || true
                cp -r /host-claude/ide /claude/ 2>/dev/null || true
                cp -r /host-claude/commands /claude/ 2>/dev/null || true
                cp -r /host-claude/statsig /claude/ 2>/dev/null || true
                chown -R 1000:1000 /claude
                chmod -R 755 /claude
                echo '   ✅ Synced Claude settings from host'
            " 2>/dev/null || echo "   ⚠️  Could not sync Claude settings"
    fi

    # Fix permissions - run as root to change ownership
    docker run --rm \
        -v "ocg-claude-shared":/claude \
        --user root \
        alpine sh -c "
            # Ensure directory exists and fix ownership
            mkdir -p /claude
            chown -R 1000:1000 /claude
            chmod -R 755 /claude
            echo '   ✅ Fixed Claude auth permissions'
        " 2>/dev/null || echo "   ⚠️  Could not fix Claude auth permissions"
}

clone_deps_volumes() {
    local feature_name="$1"
    local project_name="$2"
    local volume_types=("deps" "build" "node" "plts")

    echo "📦 Setting up workspace volumes..."

    for vol_type in "${volume_types[@]}"; do
        local base_volume="ocg-${project_name}-${vol_type}-base"
        local workspace_volume="ocg-${project_name}-${vol_type}-${feature_name}"

        # Check if workspace volume already exists
        if docker volume ls | grep -q "$workspace_volume"; then
            # Check if volume has content
            has_content=$(docker run --rm -v "$workspace_volume":/check "ocg/phoenix:${project_name}" sh -c "ls -A /check 2>/dev/null | head -1")
            if [ -n "$has_content" ]; then
                echo "   ✓ Volume exists with content: $workspace_volume"
                continue
            else
                echo "   ⚠️  Volume exists but is empty: $workspace_volume"
                # Continue to clone from base
            fi
        else
            # Create new volume
            docker volume create "$workspace_volume" >/dev/null 2>&1
        fi

        # Check if base volume exists and has content
        if docker volume ls | grep -q "$base_volume"; then
            # Copy base volume to workspace volume using Phoenix container for consistent permissions
            echo "   📋 Copying $vol_type from base..."
            # Run as root to handle permissions, then fix ownership
            docker run --rm \
                -v "$base_volume":/source:ro \
                -v "$workspace_volume":/dest \
                --user root \
                "ocg/phoenix:${project_name}" bash -c "
                    # Copy all files as root first
                    cp -a /source/. /dest/ 2>/dev/null || true
                    # Then fix ownership to ubuntu
                    chown -R ubuntu:ubuntu /dest
                    echo '   ✅ Copied $vol_type data'
                "
            echo "   ✅ Copied $vol_type from base"
        else
            echo "   ℹ️  No base $vol_type to copy (run 'ocg prepare' in main branch to speed up startup)"
        fi
    done

    echo "✅ Workspace volumes ready"
    return 0
}

build_base_image() {
    local dockerfile_path="$1"
    local project_root="$2"
    local project_name="$(basename "$project_root")"
    local image_tag="ocg/phoenix:${project_name}"

    # Detect versions for this project
    detect_versions "$project_root"
    export_versions

    echo "🔨 Building base Docker image..."
    echo "   Project: $project_name"
    echo "   Elixir: $ELIXIR_VERSION"
    echo "   Erlang/OTP: $OTP_VERSION"

    # Use BuildKit for better build performance and add DNS configuration
    if DOCKER_BUILDKIT=1 docker build \
        --network=host \
        --build-arg ELIXIR_VERSION="$ELIXIR_VERSION" \
        --build-arg OTP_VERSION="$OTP_VERSION" \
        -f "$dockerfile_path" \
        -t "$image_tag" \
        "$(dirname "$dockerfile_path")"; then
        echo "✅ Base image built successfully: $image_tag"

        # Create base deps volume if it doesn't exist
        if ! docker volume ls | grep -q "ocg-deps-base"; then
            echo "📦 Creating base dependencies volume..."
            docker volume create ocg-deps-base
        fi

        return 0
    else
        echo "❌ Failed to build base image"
        return 1
    fi
}

create_docker_compose() {
    local workspace_path="$1"
    local feature_name="$2"
    local template_path="$3"
    local project_name="$4"
    local compose_path="$workspace_path/codegen/docker-compose.yml"

    # Ensure codegen directory exists
    mkdir -p "$workspace_path/codegen"

    # Read environment variables
    source "$workspace_path/.env"

    # Copy and substitute template
    cp "$template_path" "$compose_path"

    # Perform substitutions
    sed -i '' "s|{{CODEGEN_DIR}}|$SCRIPT_DIR|g" "$compose_path"
    sed -i '' "s|{{DB_NAME_PREFIX}}|$DB_NAME_PREFIX|g" "$compose_path"
    sed -i '' "s|{{FEATURE_NAME}}|$feature_name|g" "$compose_path"
    sed -i '' "s|{{HOME}}|$HOME|g" "$compose_path"
    sed -i '' "s|{{PLAYWRIGHT_MCP_PORT}}|$PLAYWRIGHT_MCP_PORT|g" "$compose_path"
    sed -i '' "s|{{PORT_TEST}}|$PORT_TEST|g" "$compose_path"
    sed -i '' "s|{{PORT}}|$PORT|g" "$compose_path"
    sed -i '' "s|{{PROJECT_NAME}}|$project_name|g" "$compose_path"
    sed -i '' "s|{{WORKSPACE_PATH}}|$workspace_path|g" "$compose_path"

    echo "✅ Created docker-compose.yml for workspace"
}

start_docker_workspace() {
    local workspace_path="$1"
    local feature_name="$2"

    cd "$workspace_path"

    # Get project name for container naming
    local project_root="$(cd "$workspace_path/../../.." && pwd)"
    local project_name="$(basename "$project_root")"
    local container_name="ocg-${project_name}-${feature_name}"

    echo "🐳 Starting Docker container for workspace..."

    # Check if container already exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "📦 Container already exists, starting it..."
        docker compose -f codegen/docker-compose.yml start
    else
        echo "📦 Creating and starting new container..."
        docker compose -f codegen/docker-compose.yml up -d
    fi

    # Wait for container to be ready
    local max_attempts=10
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if docker exec "${container_name}" echo "Container ready" &>/dev/null; then
            echo "✅ Container is ready"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    echo "❌ Container failed to start properly"
    echo "📋 Container logs:"
    docker logs "${container_name}" 2>&1 || echo "No logs available"
    return 1
}

exec_in_container() {
    local feature_name="$1"
    shift
    local command="$@"

    # Detect versions for dynamic paths
    local project_root
    if [ -n "$WORKSPACE_ROOT" ]; then
        project_root="$(cd "$WORKSPACE_ROOT/../../.." && pwd)"
    else
        project_root="$(pwd)"
    fi

    # Get project name for container naming
    local project_name="$(basename "$project_root")"
    local container_name="ocg-${project_name}-${feature_name}"

    detect_versions "$project_root"
    export_versions

    # Execute as ubuntu user with proper environment
    # Using bash without -l to avoid potential login script issues
    docker exec -it --user ubuntu --workdir /workspace "${container_name}" bash -c "
        export PATH='${ELIXIR_BIN_PATH}:${OTP_BIN_PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        export HOME='/home/ubuntu'
        export DATABASE_HOST='host.docker.internal'
        $command
    "
}

setup_container_startup() {
    local workspace_path="$1"
    local startup_script="$workspace_path/codegen/startup.sh"

    # Detect versions for this project
    local project_root="$(cd "$workspace_path/../../../" && pwd)"
    detect_versions "$project_root"
    export_versions

    mkdir -p "$workspace_path/codegen"

    cat >"$startup_script" <<EOF
#!/bin/bash
set -e  # Exit on any error
echo "🐳 Container startup script running..."

# Set up environment
cd /workspace

# Set umask to ensure files are created with correct permissions
umask 022

# Fix git worktree configuration for container environment
echo "🔧 Setting up git configuration for container..."

# We're already in /workspace due to WORKDIR setting
cd /workspace

# Fix git worktree paths using symlinks
echo "🔧 Setting up git worktree compatibility..."

# Read the host git path from .git file
if [ -f .git ] && grep -q "gitdir:" .git; then
    HOST_GIT_PATH=\$(grep "gitdir:" .git | sed 's/^gitdir:[ ]*//' | tr -d '\r\n')
    HOST_GIT_DIR=\$(dirname "\$HOST_GIT_PATH")
    
    echo "   Host git path: \$HOST_GIT_PATH"
    
    # Create parent directories if they don't exist
    sudo mkdir -p "\$HOST_GIT_DIR"
    
    # Create symlink from host path to container path
    # Extract the project name from the path
    PROJECT_PATH=\$(echo "\$HOST_GIT_PATH" | sed 's#/.git/worktrees/.*#/.git#')
    sudo ln -sfn /repo/.git "\$PROJECT_PATH" 2>/dev/null || true
    
    echo "   Created symlink: \$PROJECT_PATH -> /repo/.git"
    
    # Also handle submodules - find all .git files in subdirectories
    echo "   Checking for submodules..."
    find . -name ".git" -type f ! -path "./.git" 2>/dev/null | while read -r submodule_git; do
        if grep -q "gitdir:" "\$submodule_git"; then
            SUBMODULE_HOST_PATH=\$(grep "gitdir:" "\$submodule_git" | sed 's/^gitdir:[ ]*//' | tr -d '\r\n')
            SUBMODULE_PROJECT_PATH=\$(echo "\$SUBMODULE_HOST_PATH" | sed 's#/.git/.*#/.git#')
            
            if [ "\$SUBMODULE_PROJECT_PATH" != "\$PROJECT_PATH" ]; then
                echo "   Found submodule: \$submodule_git"
                sudo mkdir -p "\$(dirname "\$SUBMODULE_PROJECT_PATH")"
                sudo ln -sfn /repo/.git "\$SUBMODULE_PROJECT_PATH" 2>/dev/null || true
                echo "   Created submodule symlink: \$SUBMODULE_PROJECT_PATH -> /repo/.git"
            fi
        fi
    done
fi

# Set basic git config to prevent warnings
git config --global user.name "OCG Container"
git config --global user.email "ocg@container.local"

# Disable Git LFS in container to avoid write permission issues
git config --global filter.lfs.smudge "cat"
git config --global filter.lfs.process ""
git config --global filter.lfs.clean "cat"
git config --global filter.lfs.required false
echo "   Disabled Git LFS (read-only container)"

# Test if git is working
echo "🔍 Testing git access..."
if git status &>/dev/null; then
    echo "   ✅ Git is working properly!"
    echo "   Current branch: \$(git branch --show-current)"
    echo "   Repository root: \$(git rev-parse --show-toplevel)"
else
    echo "   ❌ Git is not working properly"
    echo "   Git error:"
    git status 2>&1 | head -5
fi

# Load environment variables
if [ -f .env ]; then
    echo "📋 Loading environment variables..."
    export $(cat .env | grep -v '^#' | xargs)
fi

# Set up Elixir environment with correct PATH
echo "🔧 Setting up Elixir environment..."
export HOME="/home/ubuntu"
export PATH="$ELIXIR_BIN_PATH:$OTP_BIN_PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Set up database connection for container
echo "🔧 Setting up database connection..."
# Export DATABASE_HOST for direct connection to host
export DATABASE_HOST="host.docker.internal"
echo "   ✅ Database configured to connect to host directly"

# Set up browser environment for Wallaby
echo "🌐 Setting up browser environment for Wallaby..."
export WALLABY_DRIVER=chrome
export WALLABY_CHROME_BINARY=/usr/bin/google-chrome-stable
export CHROMEDRIVER_PATH=/usr/bin/chromedriver
export CHROME_ARGS="--no-sandbox --disable-dev-shm-usage --disable-gpu --headless"

# Add to .bashrc for persistence
echo 'export DATABASE_HOST=host.docker.internal' >> /home/ubuntu/.bashrc
echo 'export WALLABY_DRIVER=chrome' >> /home/ubuntu/.bashrc
echo 'export WALLABY_CHROME_BINARY=/usr/bin/google-chrome-stable' >> /home/ubuntu/.bashrc
echo 'export CHROMEDRIVER_PATH=/usr/bin/chromedriver' >> /home/ubuntu/.bashrc
echo 'export CHROME_ARGS="--no-sandbox --disable-dev-shm-usage --disable-gpu --headless"' >> /home/ubuntu/.bashrc


# Verify Chrome and ChromeDriver are available
echo "🔍 Verifying browser setup..."
if [ -e /usr/bin/google-chrome-stable ]; then
    echo "✅ Chrome found at: /usr/bin/google-chrome-stable"
    /usr/bin/google-chrome-stable --version || echo "⚠️  Could not get Chrome version"
else
    echo "❌ Chrome not found at expected location"
fi

if [ -e /usr/bin/chromedriver ]; then
    echo "✅ ChromeDriver found at: /usr/bin/chromedriver"
    /usr/bin/chromedriver --version 2>/dev/null || echo "⚠️  Could not get ChromeDriver version"
else
    echo "❌ ChromeDriver not found at expected location"
fi

# Verify mix is available before proceeding
echo "🔍 Verifying Elixir installation..."
if ! command -v mix >/dev/null 2>&1; then
    echo "❌ FATAL: mix command not found in PATH"
    echo "   Expected at: $ELIXIR_BIN_PATH/mix"
    echo "   Current PATH: \$PATH"
    exit 1
fi
echo "✅ Elixir found: \$(which mix)"

# Initialize Elixir tools
echo "🔧 Initializing Elixir tools..."
mix local.hex --force
mix local.rebar --force

# Install Claude Code CLI if not present  
echo "🤖 Installing Claude Code CLI..."
export NPM_CONFIG_PREFIX=/home/ubuntu/.npm-global
export PATH=\$NPM_CONFIG_PREFIX/bin:\$PATH
export CLAUDE_CONFIG_DIR=/home/ubuntu/.claude
mkdir -p /home/ubuntu/.npm-global

if ! command -v claude >/dev/null 2>&1; then
    echo "   Installing Claude Code globally..."
    npm install -g @anthropic-ai/claude-code
    echo "✅ Claude Code installed"
else
    echo "✅ Claude Code already available"
fi

# Add NPM_CONFIG_PREFIX and CLAUDE_CONFIG_DIR to .bashrc for persistent access
echo 'export NPM_CONFIG_PREFIX=/home/ubuntu/.npm-global' >> /home/ubuntu/.bashrc
echo 'export PATH=\$NPM_CONFIG_PREFIX/bin:\$PATH' >> /home/ubuntu/.bashrc
echo 'export CLAUDE_CONFIG_DIR=/home/ubuntu/.claude' >> /home/ubuntu/.bashrc

# Verify Claude Code is working
if command -v claude >/dev/null 2>&1; then
    echo "✅ Claude Code installed"
else
    echo "❌ Claude Code installation failed"
    exit 1
fi

# Since we're running as ubuntu user, we should have write access to volumes
echo "📁 Checking workspace structure..."

# Always ensure dependencies are up to date for this workspace
echo "📦 Ensuring dependencies are up to date..."
mix deps.get || echo "⚠️  Failed to get dependencies"

# Always compile to ensure workspace-specific changes are built
echo "🔨 Compiling project..."
mix compile || echo "⚠️  Failed to compile"

# Ensure test environment is compiled for CI
echo "🔧 Compiling test environment..."
MIX_ENV=test mix compile || echo "⚠️  Failed to compile test environment"

# Dialyzer PLTs are now handled via volume cloning from base
# They're built during 'ocg prepare' and copied to workspaces

# Setup database
echo "🗄️ Setting up database..."
# First check if postgres is reachable
if mix ecto.create 2>&1 | grep -q "could not connect"; then
    echo "⚠️  Could not connect to database. Make sure PostgreSQL is running."
    echo "   You may need to run: brew services start postgresql@15"
else
    mix ecto.create || echo "✅ Database already exists"
    mix ecto.migrate || echo "⚠️  Failed to run migrations"
fi

# Install Node dependencies if needed
if [ -d "assets" ] && [ -f "assets/package.json" ]; then
    if [ ! -d "assets/node_modules" ] || [ -z "$(ls -A assets/node_modules 2>/dev/null)" ]; then
        echo "📦 Installing Node dependencies..."
        cd assets && npm install && cd .. || echo "⚠️  Failed to install Node dependencies"
    else
        echo "✅ Node dependencies found"
    fi
fi

echo ""
echo "✅ Container setup complete!"
echo ""
echo "🚀 Starting Phoenix server in background..."
nohup mix phx.server > codegen/mix_phx_server.log 2>&1 &
echo "✅ Phoenix server started on port \${PORT:-4000}"
echo "🌐 Server logs: codegen/mix_phx_server.log"
echo ""

# Run CI checks in background if available
if [ -f "codegen/ci.sh" ]; then
    echo "🔍 Running CI checks in background..."
    export CI_BACKGROUND=1
    nohup ./codegen/ci.sh > codegen/ci.log 2>&1 &
    echo "✅ CI checks started - see codegen/ci.log for progress"
    echo ""
fi

echo "🤖 To start Claude Code, run:"
echo "   claude --model sonnet"
echo ""

# Create completion marker file
echo "✅ Startup complete" > /workspace/codegen/.startup_complete
echo "📋 Startup completion marker created"

# Remove claude_wait file if it exists (for container mode)
if [ -f /workspace/codegen/.claude_wait ]; then
    rm -f /workspace/codegen/.claude_wait
    echo "🔓 Released Claude Code to start"
fi

# Keep container running without showing Phoenix logs
echo "🔄 Container ready!"
echo "   Phoenix server running on port \${PORT:-4000}"
echo "   Press Ctrl+C to stop"
sleep infinity
EOF

    chmod +x "$startup_script"
}
