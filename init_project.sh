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
WITH_FLUTTER=false
IS_MONOREPO=false
WITH_SQLITE=false
GITHUB_URL=""
FLY_APP_PREFIX=""
AGENT_OVERRIDE=""
MODEL_OVERRIDE=""

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
    --flutter)
        WITH_FLUTTER=true
        IS_MONOREPO=true
        shift
        ;;
    --sqlite)
        WITH_SQLITE=true
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
    --model | -m)
        MODEL_OVERRIDE="$2"
        shift 2
        ;;
    --help | -h)
        echo "Usage: ocg init <project-name> [options]"
        echo ""
        echo "Options:"
        echo "  --poc                    Create POC project (skips infrastructure)"
        echo "  --ash                    Include Ash Framework"
        echo "  --flutter                Create Flutter mobile app (creates backend/ + mobile/)"
        echo "  --sqlite                 Use SQLite instead of PostgreSQL"
        echo "  --github-url <url>       GitHub repo URL (required if NOT --poc)"
        echo "  --fly-app-prefix <pfx>   Fly.io app prefix (optional, defaults to project-name)"
        echo "  --model, -m <model>      AI model to use (haiku/sonnet/opus, default: opus)"
        echo "  --agent, -a <name>       AI agent to use (default: from config)"
        echo ""
        echo "Examples:"
        echo "  ocg init my_app --github-url https://github.com/user/my_app"
        echo "  ocg init my_poc --poc --ash"
        echo "  ocg init my_app --flutter --sqlite --github-url https://github.com/user/my_app"
        echo "  ocg init my_app --model sonnet --github-url https://github.com/user/my_app"
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

# Don't set default fly-app-prefix - leave empty to skip Fly.io setup

# Check if directory already exists
if [ -d "$PROJECT_NAME" ]; then
    echo "❌ Error: Directory '$PROJECT_NAME' already exists"
    exit 1
fi

# Check for required Mix archives
echo "🔍 Checking prerequisites..."

if ! mix archive 2>&1 | grep "phx_new" >/dev/null; then
    echo "❌ Error: Phoenix archive (phx_new) not installed"
    echo "Install with: mix archive.install hex phx_new"
    exit 1
fi

if [ "$WITH_ASH" = true ]; then
    if ! mix archive 2>&1 | grep "igniter_new" >/dev/null; then
        echo "❌ Error: Igniter archive (igniter_new) not installed"
        echo "Install with: mix archive.install hex igniter_new"
        exit 1
    fi
fi

if [ "$WITH_FLUTTER" = true ]; then
    if ! command -v flutter &>/dev/null; then
        echo "❌ Error: Flutter not installed"
        echo "Install from: https://docs.flutter.dev/get-started/install"
        exit 1
    fi
    echo "✅ Flutter version: $(flutter --version | head -1)"
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

# Create project structure
echo ""
if [ "$IS_POC" = true ]; then
    echo "🚀 Creating POC project: $PROJECT_NAME"
else
    echo "🚀 Creating regular project: $PROJECT_NAME"
fi

if [ "$IS_MONOREPO" = true ]; then
    echo "   Architecture: Monorepo"
    mkdir -p "$PROJECT_NAME"
    cd "$PROJECT_NAME"
    PROJECT_ROOT="$(pwd)"

    BACKEND_DIR="backend"
    echo "   Creating backend in: $BACKEND_DIR/"

    if [ "$WITH_ASH" = true ]; then
        echo "   With Ash Framework (using Igniter)"
        ASH_DB_FLAG=""
        if [ "$WITH_SQLITE" = true ]; then
            ASH_DB_FLAG="ash_sqlite"
        else
            ASH_DB_FLAG="ash_postgres"
        fi
        mix igniter.new "$BACKEND_DIR" \
            --install "ash,ash_phoenix,$ASH_DB_FLAG" \
            --with phx.new \
            --yes
    else
        echo "   Standard Phoenix LiveView"
        PHX_DB_FLAG=""
        if [ "$WITH_SQLITE" = true ]; then
            PHX_DB_FLAG="--database sqlite3"
        fi
        mix phx.new "$BACKEND_DIR" \
            --binary-id \
            $PHX_DB_FLAG \
            --install
    fi

    if [ "$WITH_FLUTTER" = true ]; then
        echo ""
        echo "📱 Creating Flutter mobile app..."
        flutter create mobile \
            --org com.$(echo "$PROJECT_NAME" | tr '_' '.') \
            --platforms android,ios

        echo "✅ Flutter app created at: mobile/"

        echo ""
        echo "🔧 Ensuring all platform files are present..."
        cd mobile
        flutter create . --platforms android,ios
        cd ..
        echo "✅ Platform files initialized"

        echo ""
        echo "🔧 Configuring mobile to use local backend..."

        mkdir -p mobile/lib/config
        cat >mobile/lib/config/api_config.dart <<'DART_EOF'
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://localhost:4000',
  );

  static const String apiVersion = 'v1';

  static String get apiBaseUrl => '$baseUrl/api/$apiVersion';
}
DART_EOF
        echo "✅ Created mobile/lib/config/api_config.dart"
    fi
else
    if [ "$WITH_ASH" = true ]; then
        echo "   With Ash Framework (using Igniter)"
        ASH_DB_FLAG=""
        if [ "$WITH_SQLITE" = true ]; then
            ASH_DB_FLAG="ash_sqlite"
        else
            ASH_DB_FLAG="ash_postgres"
        fi
        mix igniter.new "$PROJECT_NAME" \
            --install "ash,ash_phoenix,$ASH_DB_FLAG" \
            --with phx.new \
            --yes
    else
        echo "   Standard Phoenix LiveView"
        PHX_DB_FLAG=""
        if [ "$WITH_SQLITE" = true ]; then
            PHX_DB_FLAG="--database sqlite3"
        fi
        mix phx.new "$PROJECT_NAME" \
            --binary-id \
            $PHX_DB_FLAG \
            --install
    fi

    cd "$PROJECT_NAME"
    PROJECT_ROOT="$(pwd)"
fi

# Clean up nested git repository for monorepo
if [ "$IS_MONOREPO" = true ]; then
    if [ -d "backend/.git" ]; then
        rm -rf backend/.git
        echo "✅ Removed nested git repository from backend/"
    fi
fi

# Initialize git
echo ""
echo "📦 Initializing git repository..."
git init

# Run optimum_gen_infra for regular projects
if [ "$IS_POC" = false ]; then
    echo ""
    echo "🏗️  Setting up infrastructure with optimum_gen_infra..."

    if [ "$IS_MONOREPO" = true ]; then
        cd "$PROJECT_ROOT/backend"
    fi

    # Build command with conditional fly-app-prefix
    infra_cmd="mix optimum.gen.infra --phoenix --ecto --github-url \"$GITHUB_URL\" --elixir-version \"$ELIXIR_VERSION\" --node-version \"$NODE_VERSION\" --otp-version \"$ERLANG_VERSION\""

    if [ -n "$FLY_APP_PREFIX" ]; then
        infra_cmd="$infra_cmd --fly-app-prefix \"$FLY_APP_PREFIX\""
    fi

    eval "$infra_cmd"

    echo "✅ Infrastructure setup complete"

    if [ "$IS_MONOREPO" = true ]; then
        cd "$PROJECT_ROOT"
        # Remove .github directory (not ready yet)
        rm -rf backend/.github
        echo "✅ Removed .github directory (will be added later)"

        # Add Makefiles for monorepo
        echo ""
        echo "📝 Adding Makefiles for monorepo structure..."

        # Root Makefile (delegates to backend and mobile)
        if [ -f "$SCRIPT_DIR/templates/monorepo-root-Makefile" ]; then
            cp "$SCRIPT_DIR/templates/monorepo-root-Makefile" "$PROJECT_ROOT/Makefile"
            echo "✅ Created root Makefile (delegates to backend + mobile)"
        fi

        # Mobile Makefile
        if [ -f "$SCRIPT_DIR/templates/mobile-Makefile" ]; then
            cp "$SCRIPT_DIR/templates/mobile-Makefile" "$PROJECT_ROOT/mobile/Makefile"
            echo "✅ Created mobile/Makefile (Flutter CI commands)"
        fi
    fi
fi

# Clean up AGENTS.md created by optimum_gen_infra/Igniter BEFORE running setup
# (setup_project.sh will create project-specific AGENTS.md in context dir and symlink it)
if [ -f "$PROJECT_ROOT/AGENTS.md" ]; then
    rm -f "$PROJECT_ROOT/AGENTS.md"
    echo "✅ Removed AGENTS.md created by optimum_gen_infra/Igniter"
fi

# Also clean up backend/AGENTS.md for monorepo
if [ "$IS_MONOREPO" = true ] && [ -f "$PROJECT_ROOT/backend/AGENTS.md" ]; then
    rm -f "$PROJECT_ROOT/backend/AGENTS.md"
    echo "✅ Removed backend/AGENTS.md (AGENTS.md belongs at monorepo root)"
fi

# Run ocg setup
echo ""
echo "🔧 Running OCG setup..."

# Set environment variables for ocg setup
export TARGET_REPO_PATH="$PROJECT_ROOT"
export ORIGINAL_WORKING_DIR="$PROJECT_ROOT"

# Build setup command with optional flags
SETUP_CMD=("$SCRIPT_DIR/setup_project.sh")
if [ -n "$MODEL_OVERRIDE" ]; then
    SETUP_CMD+=(--model "$MODEL_OVERRIDE")
fi
if [ -n "$AGENT_OVERRIDE" ]; then
    SETUP_CMD+=(--agent "$AGENT_OVERRIDE")
fi

"${SETUP_CMD[@]}"

echo ""
echo "✅ Project created successfully!"
echo ""
echo "📁 Project: $PROJECT_NAME"
if [ "$IS_POC" = true ]; then
    echo "🎯 Type: POC (Proof of Concept)"
    echo "📝 Focus: Rapid validation over production features"
else
    echo "🎯 Type: Regular (Production-ready)"
    if [ -n "$FLY_APP_PREFIX" ]; then
        echo "📝 Infrastructure: CI/CD, Docker, Fly.io deployment"
    else
        echo "📝 Infrastructure: CI/CD (no deployment configured)"
    fi
fi

if [ "$IS_MONOREPO" = true ]; then
    echo "🏗️  Architecture: Monorepo"
    if [ "$WITH_FLUTTER" = true ]; then
        echo "🛠️  Stack: Phoenix LiveView + Flutter Mobile"
        echo "   Backend: ./backend/"
        echo "   Mobile: ./mobile/"
    else
        echo "🛠️  Stack: Phoenix LiveView (Monorepo)"
        echo "   Backend: ./backend/"
    fi
    if [ "$WITH_ASH" = true ]; then
        echo "   + Ash Framework"
    fi
else
    if [ "$WITH_ASH" = true ]; then
        echo "🛠️  Stack: Phoenix LiveView + Ash Framework"
    else
        echo "🛠️  Stack: Phoenix LiveView"
    fi
fi

echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_NAME"
echo "  2. Review ./codegen/PROJECT_CONTEXT.md (auto-filled by AI)"
if [ "$IS_MONOREPO" = true ]; then
    echo "  3. Start backend: cd backend && mix phx.server"
    echo "  4. Run mobile: cd mobile && flutter run"
    echo "  5. Create feature workspace: ocg new <feature-name>"
elif [ "$IS_POC" = true ]; then
    echo "  3. Create POC workspace: ocg new poc"
else
    echo "  3. Create feature workspace: ocg new <feature-name>"
fi
