#!/bin/bash
# Script to prepare the OCG environment
# Supports both native (default) and container modes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

# Check for --container flag
CONTAINER_MODE=false
for arg in "$@"; do
    if [ "$arg" = "--container" ]; then
        CONTAINER_MODE=true
        break
    fi
done

if [ "$CONTAINER_MODE" = true ]; then
    # Container mode - build Docker image and prepare volumes
    source "$SCRIPT_DIR/docker_utils.sh"
    source "$SCRIPT_DIR/detect_versions.sh"

    # Detect versions for this project
    if ! detect_versions "$(pwd)"; then
        echo "❌ Version detection failed. Please fix the version issues above."
        exit 1
    fi
    export_versions

    echo "🚀 OCG Environment Preparation (Container Mode)"
    echo "=============================================="
    echo "Detected versions:"
    echo "  • Elixir: $ELIXIR_VERSION"
    echo "  • Erlang/OTP: $OTP_VERSION"
    echo ""
    echo "This will:"
    echo "  • Build/update the Docker base image with detected versions"
    echo "  • Compile your project's dependencies"
    echo "  • Create base volumes for faster workspace creation"
    echo ""

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        echo "❌ Docker is not running. Please start Docker Desktop."
        exit 1
    fi

    # Get the main project directory
    if [ ! -f "mix.exs" ]; then
        echo "❌ This script must be run from your Phoenix project root directory"
        echo "   Current directory: $(pwd)"
        exit 1
    fi

    # Get project name for project-specific image
    PROJECT_NAME=$(basename "$(pwd)")
    IMAGE_NAME="ocg/phoenix:${PROJECT_NAME}"

    # Check if we need to rebuild the image by comparing versions
    echo "🔍 Checking if Docker image needs rebuilding..."

    # Get current image build args if image exists
    IMAGE_ELIXIR=""
    IMAGE_OTP=""
    if docker images | grep -q "ocg/phoenix.*${PROJECT_NAME}"; then
        IMAGE_ELIXIR=$(docker inspect "$IMAGE_NAME" 2>/dev/null | grep -o '"ELIXIR_VERSION=[^"]*"' | cut -d'=' -f2 | tr -d '"' || echo "")
        IMAGE_OTP=$(docker inspect "$IMAGE_NAME" 2>/dev/null | grep -o '"OTP_VERSION=[^"]*"' | cut -d'=' -f2 | tr -d '"' || echo "")
    fi

    # Check for --force flag
    FORCE_REBUILD=false
    if [[ " $* " =~ " --force " ]] || [[ " $* " =~ " -f " ]]; then
        FORCE_REBUILD=true
        echo "🔄 Force rebuild requested"
    fi

    # Check if versions match
    REBUILD_NEEDED=false
    if [ "$FORCE_REBUILD" = true ]; then
        REBUILD_NEEDED=true
        echo "📋 Forcing Docker image rebuild"
    elif [ "$IMAGE_ELIXIR" != "$ELIXIR_VERSION" ] || [ "$IMAGE_OTP" != "$OTP_VERSION" ]; then
        REBUILD_NEEDED=true
        echo "📋 Version changes detected:"
        [ "$IMAGE_ELIXIR" != "$ELIXIR_VERSION" ] && echo "   Elixir: $IMAGE_ELIXIR → $ELIXIR_VERSION"
        [ "$IMAGE_OTP" != "$OTP_VERSION" ] && echo "   OTP: $IMAGE_OTP → $OTP_VERSION"
    elif [ -z "$IMAGE_ELIXIR" ] || [ -z "$IMAGE_OTP" ]; then
        REBUILD_NEEDED=true
        echo "📋 No existing image found"
    else
        echo "✅ Docker image is up to date (Elixir: $ELIXIR_VERSION, OTP: $OTP_VERSION)"
    fi

    # Build or update base image with detected versions
    if [ "$REBUILD_NEEDED" = true ]; then
        echo "🔨 Building/updating Docker base image..."
        echo "   This may take a few minutes..."

        # Add --no-cache flag if force rebuild is requested
        DOCKER_BUILD_ARGS=""
        if [ "$FORCE_REBUILD" = true ]; then
            DOCKER_BUILD_ARGS="--no-cache"
        fi

        if ! DOCKER_BUILDKIT=1 docker build \
            $DOCKER_BUILD_ARGS \
            --build-arg ELIXIR_VERSION="$ELIXIR_VERSION" \
            --build-arg OTP_VERSION="$OTP_VERSION" \
            -f "$SCRIPT_DIR/dockerfiles/Dockerfile.phoenix" \
            -t "$IMAGE_NAME" \
            "$SCRIPT_DIR"; then
            echo "❌ Failed to build base image"
            exit 1
        fi
        echo "✅ Base image rebuilt with new versions"
    else
        echo "⚡ Using existing Docker image (no rebuild needed)"
    fi
    echo "✅ Base image ready"

    echo "📦 Preparing base volumes for project: $PROJECT_NAME"

    # Create project-specific volumes
    docker volume create "ocg-${PROJECT_NAME}-deps-base" 2>/dev/null || true
    docker volume create "ocg-${PROJECT_NAME}-build-base" 2>/dev/null || true
    docker volume create "ocg-${PROJECT_NAME}-node-base" 2>/dev/null || true
    docker volume create "ocg-${PROJECT_NAME}-plts-base" 2>/dev/null || true

    echo "🔨 Compiling dependencies in base volumes..."
    echo "   This may take a few minutes on first run..."

    # Run as ubuntu user to ensure consistent permissions
    docker run --rm -it \
        -v "$(pwd)":/workspace \
        -v "ocg-${PROJECT_NAME}-deps-base":/workspace/deps \
        -v "ocg-${PROJECT_NAME}-build-base":/workspace/_build \
        -v "ocg-${PROJECT_NAME}-node-base":/workspace/assets/node_modules \
        -v "ocg-${PROJECT_NAME}-plts-base":/workspace/priv/plts \
        -w /workspace \
        --user ubuntu:ubuntu \
        "$IMAGE_NAME" bash -c "
            set -e
            
            echo '📋 Setting up build environment...'
            
            # Ensure volume directories exist and have correct ownership
            echo '🔧 Setting up volume permissions...'
            sudo mkdir -p /workspace/deps /workspace/_build /workspace/assets/node_modules /workspace/priv/plts
            sudo chown -R ubuntu:ubuntu /workspace/deps /workspace/_build /workspace/assets/node_modules /workspace/priv/plts
            sudo chmod -R 755 /workspace/deps /workspace/_build /workspace/assets/node_modules /workspace/priv/plts
            
            # Set up PATH for Elixir with detected versions
            export PATH=\"${ELIXIR_BIN_PATH}:${OTP_BIN_PATH}:\$PATH\"
            export HOME=/home/ubuntu
            
            echo '🔧 Setting up Elixir tools...'
            mix local.hex --force
            mix local.rebar --force
            
            echo '📦 Getting dependencies...'
            mix deps.get
            
            echo '🔨 Compiling application for dev environment...'
            MIX_ENV=dev mix compile
            
            echo '🔨 Compiling application for test environment...'
            MIX_ENV=test mix compile
            
            # Handle assets if they exist
            if [ -f assets/package.json ]; then
                echo '📦 Installing Node dependencies...'
                cd assets
                npm install
                cd ..
            fi
            
            # Build Dialyzer PLTs if project uses dialyxir
            if grep -q 'dialyxir' mix.exs 2>/dev/null; then
                echo '🔧 Building Dialyzer PLTs (this may take several minutes)...'
                mix dialyzer --plt || echo '⚠️  Failed to build Dialyzer PLTs'
            fi
            
            # No need to fix permissions - we're running as ubuntu user from the start
            
            echo '✅ Dependencies compiled successfully!'
        "

    echo ""
    echo "✅ Base dependencies setup complete!"
    echo "================================"
    echo "🏷️  Project: $PROJECT_NAME"
    echo "📦 Created volumes:"
    echo "   - ocg-${PROJECT_NAME}-deps-base (Elixir dependencies)"
    echo "   - ocg-${PROJECT_NAME}-build-base (Build artifacts for dev & test)"
    echo "   - ocg-${PROJECT_NAME}-node-base (Node modules)"
    echo "   - ocg-${PROJECT_NAME}-plts-base (Dialyzer PLTs)"
    echo ""
    echo "💡 New workspaces for '$PROJECT_NAME' will now start with these pre-compiled dependencies"
    echo "🧪 Both dev and test environments are pre-compiled for faster testing"
    echo "🔄 Run this script again whenever you add new dependencies to mix.exs"

else
    # Native mode - use mise to manage Elixir/Erlang
    REPO_ROOT="$TARGET_REPO_PATH"

    echo "🔧 Preparing development environment (Native Mode)..."
    echo "📁 Project: $REPO_ROOT"

    # Check if mise is installed
    if ! command -v mise >/dev/null 2>&1; then
        echo "❌ Mise is not installed"
        echo "   Please install mise first:"
        echo "   curl https://mise.run | sh"
        echo "   Then add mise to your shell configuration"
        exit 1
    fi

    # Check if .tool-versions exists
    if [ ! -f "$REPO_ROOT/.tool-versions" ]; then
        echo "❌ No .tool-versions file found in project root"
        echo "   Create a .tool-versions file with your desired Elixir and Erlang versions"
        echo "   Example:"
        echo "   erlang 26.2.5"
        echo "   elixir 1.16.3-otp-26"
        exit 1
    fi

    echo "✅ Found .tool-versions file"

    cd "$REPO_ROOT"

    echo "📋 Reading .tool-versions file:"
    cat .tool-versions | while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        echo "   $line"
    done

    echo ""
    echo "🔨 Installing tools via mise..."

    mise trust .
    mise install

    # Verify installations
    echo ""
    echo "✅ Verifying installations:"
    if command -v elixir >/dev/null 2>&1; then
        echo "   Elixir: $(elixir --version | head -n1)"
    else
        echo "❌ Elixir not found after installation"
        exit 1
    fi

    if command -v erl >/dev/null 2>&1; then
        echo "   Erlang: $(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell 2>/dev/null | tr -d '\"')"
    else
        echo "❌ Erlang not found after installation"
        exit 1
    fi

    echo ""
    echo "🎉 Environment preparation complete!"
    echo ""
    echo "💡 Next step: Run $OCG_CMD new <feature-name> to create a workspace"
fi
