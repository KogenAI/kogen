#!/bin/bash

# Claude Code wrapper script for workspace terminal tab
# Runs Claude Code inside the Docker container

FEATURE_NAME="$(basename "$(pwd)")"
PROJECT_NAME="$(basename "$(cd ../../.. && pwd)")"
CONTAINER_NAME="ocg-${PROJECT_NAME}-${FEATURE_NAME}"

# Only wait if the startup wait file exists
if [ -f codegen/.claude_wait ]; then
    echo "⏳ Waiting for startup to complete..."
    while [ -f codegen/.claude_wait ]; do
        sleep 1
    done
fi

# Wait for container to be up and running
echo "⏳ Waiting for Docker container to start..."
while true; do
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✅ Docker container '${CONTAINER_NAME}' is running"
        break
    fi
    sleep 2
done

# Wait for container startup script to complete
echo "⏳ Waiting for workspace initialization to complete..."
while true; do
    if docker exec "${CONTAINER_NAME}" test -f /workspace/codegen/.startup_complete 2>/dev/null; then
        echo "✅ Workspace initialization complete"
        break
    fi
    sleep 2
done

echo "🤖 Starting Claude Code inside Docker container..."
echo ""
echo "📝 This will run Claude Code with the prepared prompt"
echo "   You'll be working inside the container environment"
echo ""

# Run Claude Code inside the container
docker exec -it "${CONTAINER_NAME}" bash -c "
    cd /workspace
    export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=true
    export SHELL=/bin/bash
    export NPM_CONFIG_PREFIX=/home/ubuntu/.npm-global
    export PATH=\$NPM_CONFIG_PREFIX/bin:\$PATH
    export CLAUDE_CONFIG_DIR=/home/ubuntu/.claude
    
    if command -v claude >/dev/null 2>&1; then
        echo '🚀 Starting Claude session...'
        # Start Claude session with prompt
        claude --model {{MODEL}} --dangerously-skip-permissions <codegen/PROMPT.md
    else
        echo '❌ Claude CLI not found in container.'
        echo '   PATH: \$PATH'
        echo '   Please ensure the container image includes Claude Code CLI.'
        echo ''
        echo '   You can install it manually inside the container:'
        echo '   npm install -g @anthropic-ai/claude-code'
    fi
"

echo ""
echo "✅ Claude Code session ended"
echo "💡 To start a new session, run this task again"
