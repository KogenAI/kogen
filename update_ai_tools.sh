#!/bin/bash

# Update all AI agents (Claude Code, Codex, Cursor CLI)

set -e

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Updating all AI agents (Claude Code, Codex, Cursor CLI)..."
echo ""

# Update Claude Code — check npm registry first to skip the slow update when already current
echo "🤖 Updating Claude Code..."
hash -r 2>/dev/null || true
if command -v claude >/dev/null 2>&1; then
    current=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    latest=$(curl -s --max-time 5 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
    if [ -n "$latest" ] && [ "$current" = "$latest" ]; then
        echo "   ✅ Claude Code already up to date ($current)"
    else
        echo "   ⬆️  Updating $current → $latest"
        claude update
        echo "   ✅ Claude Code updated"
    fi
else
    echo "   ⚠️  Claude Code not installed, skipping"
fi
echo ""

# Update Codex CLI (only if installed)
hash -r 2>/dev/null || true
if command -v codex >/dev/null 2>&1; then
    echo "🤖 Updating Codex..."
    current=$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    latest=$(curl -s --max-time 5 "https://registry.npmjs.org/@openai/codex/latest" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
    if [ -n "$latest" ] && [ "$current" = "$latest" ]; then
        echo "   ✅ Codex already up to date ($current)"
    else
        echo "   ⬆️  Updating $current → $latest"
        npm install -g "@openai/codex@latest" 2>&1 || echo "   ⚠️  Codex update failed"
        echo "   ✅ Codex updated"
    fi
    echo ""
fi

# Update Cursor CLI (only if installed)
hash -r 2>/dev/null || true
if command -v cursor-agent >/dev/null 2>&1; then
    echo "🤖 Updating Cursor CLI..."
    if cursor-agent update 2>&1; then
        echo "   ✅ Cursor CLI updated"
    else
        echo "   ⚠️  Cursor CLI update failed (may require authentication - try logging in first)"
    fi
    echo ""
fi

echo "✅ All AI agents have been updated (Claude Code, Codex, Cursor CLI)!"
echo ""
echo "💡 Run 'make install' to regenerate and reinstall OCG templates and commands"
