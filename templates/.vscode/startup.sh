#!/bin/bash
set -e

echo "🚀 Initializing feature workspace..."

WORKSPACE_ROOT="$(pwd)"
FEATURE_NAME="$(basename "$WORKSPACE_ROOT")"

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

        echo "$context" > "$prompt_file"
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

echo "🔧 Activating mise and loading environment..."
if command -v mise >/dev/null 2>&1; then
    mise trust 2>/dev/null || true
    eval "$(mise activate bash)"
    eval "$(mise env)"
else
    echo "⚠️  mise not found, environment variables may not be loaded"
fi

echo "✅ Environment variables loaded"

echo "📦 Copying build artifacts from main branch..."

REPO_ROOT="$(cd ../../../ && pwd)"

if [ -d "$REPO_ROOT/.elixir_ls" ] && [ ! -d ".elixir_ls" ]; then
    cp -r "$REPO_ROOT/.elixir_ls" .
fi

if [ -d "$REPO_ROOT/deps" ] && [ ! -d "deps" ]; then
    cp -r "$REPO_ROOT/deps" .
fi

if [ -d "$REPO_ROOT/_build" ] && [ ! -d "_build" ]; then
    cp -r "$REPO_ROOT/_build" .
fi

if [ -d "$REPO_ROOT/assets/node_modules" ] && [ ! -d "assets/node_modules" ]; then
    mkdir -p assets
    cp -r "$REPO_ROOT/assets/node_modules" assets/
fi

if [ -d "$REPO_ROOT/priv/plts" ] && [ ! -d "priv/plts" ]; then
    mkdir -p priv
    cp -r "$REPO_ROOT/priv/plts" priv/
fi

echo "📦 Running mix setup..."
echo "   This will install dependencies, setup database, and build assets..."
mix setup
echo "✅ Setup complete - dependencies, database, and assets ready"

echo "🎭 Starting Playwright MCP server..."
npx @playwright/mcp@latest --port $PLAYWRIGHT_MCP_PORT --headless 2>&1 &
echo "   🚀 Playwright MCP server started in background"
echo "   ⏳ Waiting for server to be ready..."

max_attempts=10
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if lsof -i :$PLAYWRIGHT_MCP_PORT >/dev/null 2>&1; then
        echo "   ✅ Playwright MCP server is ready on port $PLAYWRIGHT_MCP_PORT"
        echo "   📊 Process ID: $(lsof -ti tcp:$PLAYWRIGHT_MCP_PORT | head -1)"
        break
    fi
    sleep 1
    attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
    echo "   ❌ Failed to start Playwright MCP server within 10 seconds"
    exit 1
fi

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
    echo "Next steps:"
    echo "✅ MCP settings opened for server configuration"
    echo "👉 Toggle server switches to restart MCP servers if needed"

    if [ "$mode" = "resume" ]; then
        echo "✅ Cursor chat opened with resume context!"
    else
        echo "✅ Cursor chat opened with feature context!"
    fi

    echo "👉 Review the content and press Enter when ready to submit"
}

echo ""
echo "🚀 Starting Phoenix server..."
echo "📝 Press Ctrl+C to stop the server"
echo ""

# Start Phoenix in background and log with colors preserved
script -F codegen/mix_phx_server.log mix phx.server >/dev/null 2>&1 &
PHOENIX_PID=$!

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

# Launch Claude Code now that Phoenix is ready
echo ""
echo "🤖 Launching Claude Code with sonnet model..."
echo "📋 Prompt has been prepared in: codegen/PROMPT.md"
echo ""

# Launch Claude Code from the workspace root so file paths work correctly
cd "$WORKSPACE_ROOT"
claude --model sonnet < codegen/PROMPT.md
