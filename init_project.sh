#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Save the directory where user ran the command
INIT_DIR="$(pwd)"

# Don't source config.sh - init doesn't need existing git repo
source "$SCRIPT_DIR/utils.sh"

# Restore original directory after sourcing utils
cd "$INIT_DIR"

# Parse arguments
PROJECT_NAME=""
IS_POC=false
WITH_ASH=false
GITHUB_URL=""
FLY_APP_PREFIX=""
AGENT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
    --poc)
        IS_POC=true
        shift
        ;;
    --ash)
        WITH_ASH=true
        shift
        ;;
    --github-url)
        GITHUB_URL="$2"
        shift 2
        ;;
    --fly-app-prefix)
        FLY_APP_PREFIX="$2"
        shift 2
        ;;
    --agent | -a)
        AGENT_OVERRIDE="$2"
        shift 2
        ;;
    --help | -h)
        echo "Usage: ocg init <project-name> [options]"
        echo ""
        echo "Options:"
        echo "  --poc                    Create POC project (skips infrastructure)"
        echo "  --ash                    Include Ash Framework"
        echo "  --github-url <url>       GitHub repo URL (required if NOT --poc)"
        echo "  --fly-app-prefix <pfx>   Fly.io app prefix (optional, defaults to project-name)"
        echo "  --agent, -a <name>       AI agent to use (default: from config)"
        echo ""
        echo "Examples:"
        echo "  ocg init my_app --github-url https://github.com/user/my_app"
        echo "  ocg init my_poc --poc --ash"
        exit 0
        ;;
    *)
        if [ -z "$PROJECT_NAME" ]; then
            PROJECT_NAME="$1"
        else
            echo "Unknown option: $1"
            exit 1
        fi
        shift
        ;;
    esac
done

# Validate project name
if [ -z "$PROJECT_NAME" ]; then
    echo "❌ Error: Project name required"
    echo "Usage: ocg init <project-name> [options]"
    exit 1
fi

# Validate github-url for regular projects
if [ "$IS_POC" = false ] && [ -z "$GITHUB_URL" ]; then
    echo "❌ Error: --github-url is required for regular projects"
    echo "Use --poc flag to create a POC project without infrastructure"
    exit 1
fi

# Set default fly-app-prefix if not provided
if [ -z "$FLY_APP_PREFIX" ]; then
    FLY_APP_PREFIX="$PROJECT_NAME"
fi

# Check if directory already exists
if [ -d "$PROJECT_NAME" ]; then
    echo "❌ Error: Directory '$PROJECT_NAME' already exists"
    exit 1
fi

# Check for required Mix archives
echo "🔍 Checking prerequisites..."

if ! mix archive | grep -q "phx_new"; then
    echo "❌ Error: Phoenix archive (phx_new) not installed"
    echo "Install with: mix archive.install hex phx_new"
    exit 1
fi

if [ "$WITH_ASH" = true ]; then
    if ! mix archive | grep -q "igniter_new"; then
        echo "❌ Error: Igniter archive (igniter_new) not installed"
        echo "Install with: mix archive.install hex igniter_new"
        exit 1
    fi
fi

# Detect latest versions using mise (only for regular projects)
if [ "$IS_POC" = false ]; then
    echo "🔍 Detecting latest versions..."

    if ! command -v mise &>/dev/null; then
        echo "❌ Error: mise not found. Install from https://mise.jdx.dev"
        exit 1
    fi

    # Get latest stable versions
    ELIXIR_VERSION=$(mise ls-remote elixir | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    ERLANG_VERSION=$(mise ls-remote erlang | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | tail -1)
    NODE_VERSION=$(mise ls-remote node | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)

    if [ -z "$ELIXIR_VERSION" ] || [ -z "$ERLANG_VERSION" ] || [ -z "$NODE_VERSION" ]; then
        echo "❌ Error: Failed to detect versions from mise"
        exit 1
    fi

    echo "✅ Detected versions:"
    echo "   Elixir: $ELIXIR_VERSION"
    echo "   Erlang/OTP: $ERLANG_VERSION"
    echo "   Node.js: $NODE_VERSION"
fi

# Create Phoenix project
echo ""
if [ "$IS_POC" = true ]; then
    echo "🚀 Creating POC project: $PROJECT_NAME"
else
    echo "🚀 Creating regular project: $PROJECT_NAME"
fi

if [ "$WITH_ASH" = true ]; then
    echo "   With Ash Framework (using Igniter)"
    mix igniter.new "$PROJECT_NAME" \
        --install ash,ash_phoenix,ash_postgres \
        --with phx.new \
        --yes
else
    echo "   Standard Phoenix LiveView"
    mix phx.new "$PROJECT_NAME" \
        --binary-id \
        --install
fi

# Change to project directory
cd "$PROJECT_NAME"
PROJECT_ROOT="$(pwd)"

# Initialize git
echo ""
echo "📦 Initializing git repository..."
git init

# Run optimum_gen_infra for regular projects
if [ "$IS_POC" = false ]; then
    echo ""
    echo "🏗️  Setting up infrastructure with optimum_gen_infra..."

    mix optimum.gen.infra \
        --phoenix \
        --ecto \
        --github-url "$GITHUB_URL" \
        --fly-app-prefix "$FLY_APP_PREFIX" \
        --elixir-version "$ELIXIR_VERSION" \
        --node-version "$NODE_VERSION" \
        --otp-version "$ERLANG_VERSION"

    echo "✅ Infrastructure setup complete"
fi

# Run ocg setup
echo ""
echo "🔧 Running OCG setup..."

# Set environment variables for ocg setup
export TARGET_REPO_PATH="$PROJECT_ROOT"
export ORIGINAL_WORKING_DIR="$PROJECT_ROOT"

"$SCRIPT_DIR/setup_project.sh"

# CRITICAL: Force-copy appropriate AGENTS template AFTER everything
# (Both Igniter and optimum_gen_infra create their own AGENTS.md)
echo ""
echo "📋 Setting up AI agent templates..."

if [ "$IS_POC" = true ]; then
    cp "$SCRIPT_DIR/templates/AGENTS-POC.md" "$PROJECT_ROOT/AGENTS.md"
    echo "✅ Copied AGENTS-POC.md template (overwrote Igniter's version)"
else
    cp "$SCRIPT_DIR/templates/AGENTS.md" "$PROJECT_ROOT/AGENTS.md"
    echo "✅ Copied AGENTS.md template (overwrote optimum_gen_infra's version)"
fi

echo ""
echo "✅ Project created successfully!"
echo ""
echo "📁 Project: $PROJECT_NAME"
if [ "$IS_POC" = true ]; then
    echo "🎯 Type: POC (Proof of Concept)"
    echo "📝 Focus: Rapid validation over production features"
else
    echo "🎯 Type: Regular (Production-ready)"
    echo "📝 Infrastructure: CI/CD, Docker, Fly.io deployment"
fi
if [ "$WITH_ASH" = true ]; then
    echo "🛠️  Stack: Phoenix LiveView + Ash Framework"
else
    echo "🛠️  Stack: Phoenix LiveView"
fi
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_NAME"
echo "  2. Review ./codegen/PROJECT_CONTEXT.md (AI-generated)"
if [ "$WITH_ASH" = true ]; then
    echo "  3. Create Ash resources: mix ash.gen.resource"
    echo "  4. Generate LiveViews: mix ash_phoenix.gen.live"
fi
if [ "$IS_POC" = true ]; then
    echo "  3. Create POC workspace: ocg new poc"
else
    echo "  3. Create feature workspace: ocg new <feature-name>"
fi
