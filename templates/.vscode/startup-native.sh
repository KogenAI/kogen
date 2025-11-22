#!/bin/zsh
set -e

echo "🚀 Initializing feature workspace..."

WORKSPACE_ROOT="$(pwd)"
FEATURE_NAME="$(basename "$WORKSPACE_ROOT")"

# Source the user's zshrc to get the full environment
if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc"
fi

# Create wait files to block tasks until ready
mkdir -p codegen
touch codegen/.ai_wait
echo "🔒 Created wait files - tasks will wait for signals"

cleanup_existing_servers() {
    echo "🧹 Cleaning up existing servers..."

    local killed_something=false

    if [ -f ".env" ]; then

        local port=$(grep "^PORT=" ".env" 2>/dev/null | cut -d'=' -f2)
        local playwright_port=$(grep "^PLAYWRIGHT_MCP_PORT=" ".env" 2>/dev/null | cut -d'=' -f2)

        if [ -n "$port" ] && lsof -ti tcp:$port >/dev/null 2>&1; then
            echo "🔄 Killing Phoenix server on port $port..."
            lsof -ti tcp:$port | xargs kill -9 2>/dev/null || true
            killed_something=true
        fi

        if [ -n "$playwright_port" ] && lsof -ti tcp:$playwright_port >/dev/null 2>&1; then
            echo "🔄 Killing Playwright MCP server on port $playwright_port..."
            lsof -ti tcp:$playwright_port | xargs kill -9 2>/dev/null || true
            killed_something=true
        fi
    fi

    if [ "$killed_something" = "true" ]; then
        sleep 1
        echo "✅ Server cleanup complete"
    else
        echo "ℹ️  No servers found to clean up"
    fi
}

prepare_context() {
    local mode="$1"

    prompt_file="codegen/PROMPT.md"
    if [ ! -f "$prompt_file" ]; then
        return 1
    fi

    if [ "$mode" = "resume" ]; then
        local git_status commit_log
        git_status=$(git status --porcelain 2>/dev/null || echo "# Unable to get git status")

        if git show-ref --verify --quiet refs/heads/main; then
            if [ "$(git rev-list --count main..HEAD 2>/dev/null)" -gt 0 ]; then
                commit_log+=$(git log --oneline main..HEAD 2>/dev/null || echo "# Unable to get commit log")
            else
                commit_log="# No commits ahead of main branch"
            fi
        else
            commit_log="# Main branch not found"
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

    echo "✅ Context prepared for AI agent"

    if [ -f ".mcp.json" ]; then
        echo "✅ MCP configuration ready (.mcp.json found)"
    fi

    return 0
}

if [ -f ".ocg_resume" ]; then
    WORKSPACE_MODE="resume"
    echo "🔄 Resume mode detected"
    rm ".ocg_resume" # Clean up flag file

    cleanup_existing_servers

    setup_automation "resume"
else
    WORKSPACE_MODE="new"
    echo "🆕 New workspace mode"

    cleanup_existing_servers

    setup_automation "new"
fi

echo "🔧 Setting up environment..."
# Load environment variables from .env file
if [ -f ".env" ]; then
    echo "📄 Loading environment from .env..."
    set -a
    source ".env"
    set +a
    echo "✅ Environment variables loaded"
else
    echo "❌ No .env file found"
    exit 1
fi

# Set up mise environment
MISE_PATH="$HOME/.local/bin/mise"
if [ ! -f "$MISE_PATH" ]; then
    MISE_PATH="$(which mise 2>/dev/null)"
fi

if [ -n "$MISE_PATH" ] && [ -f "$MISE_PATH" ]; then
    echo "🔧 Setting up mise environment..."

    # Trust the .env and .tool-versions files (in backend/ for monorepo)
    if [ "$IS_MONOREPO" = true ]; then
        cd "$BACKEND_DIR"
        $MISE_PATH trust .env 2>/dev/null || true
        $MISE_PATH trust .tool-versions 2>/dev/null || true
        $MISE_PATH trust .mise.toml 2>/dev/null || true
        cd "$WORKSPACE_ROOT"
    fi

    # Also trust at workspace root
    $MISE_PATH trust .env 2>/dev/null || true
    $MISE_PATH trust .tool-versions 2>/dev/null || true

    # Activate mise to set up shell functions
    eval "$($MISE_PATH activate zsh)"

    # Load the environment for this directory
    eval "$($MISE_PATH env)"

    echo "✅ Mise environment ready"
else
    echo "❌ Mise not found. Please run 'ocg prepare' to install dependencies"
    exit 1
fi

echo "🔧 Checking environment..."
# Check if Elixir/Erlang are available (installed via ocg prepare)
if command -v elixir >/dev/null 2>&1 && command -v erl >/dev/null 2>&1; then
    echo "✅ Elixir and Erlang available"
    if [ -n "$PORT" ] && [ -n "$PLAYWRIGHT_MCP_PORT" ]; then
        echo "✅ Environment variables loaded (PORT=$PORT, PLAYWRIGHT_MCP_PORT=$PLAYWRIGHT_MCP_PORT)"
    else
        echo "❌ Critical environment variables not set!"
        echo "   PORT=$PORT"
        echo "   PLAYWRIGHT_MCP_PORT=$PLAYWRIGHT_MCP_PORT"
        echo "   .env file may not be properly sourced"
        exit 1
    fi
else
    echo "❌ Elixir/Erlang not found. Please run: ocg prepare"
    exit 1
fi

echo "📦 Copying build artifacts from main branch..."

REPO_ROOT="$(cd ../../../ && pwd)"

if [ -d "$REPO_ROOT/.elixir_ls" ] && [ ! -d ".elixir_ls" ]; then
    cp -r "$REPO_ROOT/.elixir_ls" . 2>/dev/null || true
fi

if [ -d "$REPO_ROOT/deps" ] && [ ! -d "deps" ]; then
    cp -r "$REPO_ROOT/deps" . 2>/dev/null || true
fi

# We are copying compiled dependencies instead of building to save time.
# There are downsides to this approach, like Tidewave returning source paths from the main branch.
if [ -d "$REPO_ROOT/_build" ] && [ ! -d "_build" ]; then
    cp -r "$REPO_ROOT/_build" . 2>/dev/null || true
fi

if [ -d "$REPO_ROOT/assets/node_modules" ] && [ ! -d "assets/node_modules" ]; then
    mkdir -p assets
    cp -r "$REPO_ROOT/assets/node_modules" assets/ 2>/dev/null || true
fi

if [ -d "$REPO_ROOT/priv/plts" ] && [ ! -d "priv/plts" ]; then
    mkdir -p priv
    cp -r "$REPO_ROOT/priv/plts" priv/ 2>/dev/null || true
fi

echo "📦 Running mix setup..."
echo "   This will install dependencies, setup database, and build assets..."
mix setup
echo "✅ Setup complete - dependencies, database, and assets ready"

echo "🔍 Starting CI checks in background..."
CI_BACKGROUND=1 nohup ./codegen/ci.sh >/dev/null 2>&1 &
echo "✅ CI checks started"

echo "🎭 Starting Playwright MCP server on port $PLAYWRIGHT_MCP_PORT..."
if [ -z "$PLAYWRIGHT_MCP_PORT" ]; then
    echo "❌ PLAYWRIGHT_MCP_PORT is not set! Environment not properly loaded."
    echo "   Check that .env file exists and contains PLAYWRIGHT_MCP_PORT"
    exit 1
fi
# Start Playwright MCP server in background with script for colors
nohup script -F codegen/playwright_mcp.log npx --yes @playwright/mcp@latest --port $PLAYWRIGHT_MCP_PORT --headless --isolated >/dev/null 2>&1 &

show_workspace_summary() {
    local mode="$1"
    sleep 3 # Wait for server to start and settle

    echo ""
    echo "🎯 Feature workspace '$FEATURE_NAME' is ready!"
    echo "=================================="
    echo "🔌 Port: ${PORT:-4000}"
    echo "🎭 Playwright MCP Port: ${PLAYWRIGHT_MCP_PORT:-9222}"
    echo "🗄️  Database: {{DB_NAME_PREFIX}}_dev${MIX_DEV_PARTITION:-0}"
    echo "🌐 Server: http://localhost:${PORT:-4000}"
    echo "=================================="
}

echo ""
echo "🚀 Starting Phoenix server..."
echo "📝 Press Ctrl+C to stop the server"
echo ""

# Start Phoenix in background and log with colors preserved
nohup script -F codegen/mix_phx_server.log mix phx.server >/dev/null 2>&1 &

# Wait for Phoenix to be ready
echo "⏳ Waiting for Phoenix server to start..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if lsof -i :${PORT:-4000} >/dev/null 2>&1; then
        echo "✅ Phoenix server ready on port ${PORT:-4000}"
        break
    fi
    sleep 1
    attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
    echo "❌ Phoenix server failed to start within 30 seconds"
    exit 1
fi

# Show workspace summary BEFORE launching Claude
show_workspace_summary "$WORKSPACE_MODE"

# Launch AI agent now that Phoenix is ready
echo ""
echo "🤖 Starting AI agent task..."
echo "📋 Prompt has been prepared in: codegen/PROMPT.md"
echo ""

# Launch AI agent
cd "$WORKSPACE_ROOT"

echo "✅ All services started! Check IDE tabs for:"
echo "   🤖 AI Assistant (waiting for release)"
echo "   📊 Server logs and workspace info"
echo ""
echo "🔓 Releasing AI agent to start..."
rm -f codegen/.ai_wait

echo "🎯 Startup complete! AI agent should now be starting in its tab."
echo "📝 You can manually control AI agent by creating/removing:"
echo "   codegen/.ai_wait - blocks AI agent"
echo "📝 To rerun CI checks: ./codegen/ci.sh"
