#!/bin/bash

# Update all AI agents (Claude Code + pi)

set -e

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Updating all AI agents (Claude Code + pi)..."
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

# Update pi — npm global package @earendil-works/pi-coding-agent
echo "🤖 Updating pi..."
hash -r 2>/dev/null || true
if command -v pi >/dev/null 2>&1; then
    current_pi=$(pi --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    latest_pi=$(curl -s --max-time 5 "https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
    if [ -n "$latest_pi" ] && [ "$current_pi" = "$latest_pi" ]; then
        echo "   ✅ pi already up to date ($current_pi)"
    elif [ -n "$latest_pi" ]; then
        echo "   ⬆️  Updating pi $current_pi → $latest_pi"
        npm update -g @earendil-works/pi-coding-agent
        echo "   ✅ pi updated"
    else
        echo "   ⚠️  Could not determine latest pi version — running update anyway"
        npm update -g @earendil-works/pi-coding-agent
        echo "   ✅ pi update attempted"
    fi
else
    echo "   ⚠️  pi not installed, skipping"
fi
echo ""

echo "✅ All AI agents have been updated (Claude Code + pi)!"
echo ""
echo "💡 Run 'make install' to regenerate and reinstall OCG templates and commands"
