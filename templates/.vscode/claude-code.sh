#!/bin/bash

# Claude Code wrapper script for workspace terminal tab
# Similar to startup.sh and workspace-info.sh

echo "⏳ Waiting for Claude Code to be ready..."

# Wait for startup.sh to finish initialization
while [ -f codegen/.claude_wait ]; do
    sleep 1
done

echo "🤖 Starting Claude Code..."

export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=true
export SHELL=/bin/bash

if command -v claude >/dev/null 2>&1; then
    claude --model sonnet <codegen/PROMPT.md
else
    echo "❌ Claude CLI not found. Please install Claude CLI:"
    echo "   https://docs.anthropic.com/en/docs/build-with-claude/claude-cli"
    echo ""
    echo "   Or run manually: claude --model sonnet <codegen/PROMPT.md"
fi
