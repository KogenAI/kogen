#!/bin/bash

# Update all AI agents (Claude Code, OpenCode, Cursor CLI)

set -e

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Updating all AI agents..."
echo ""

# Update Claude Code
echo "🤖 Updating Claude Code..."
hash -r 2>/dev/null || true
if command -v claude >/dev/null 2>&1; then
    claude update
    echo "   ✅ Claude Code updated"
else
    echo "   ⚠️  Claude Code not installed, skipping"
fi
echo ""

# Update OpenCode
echo "🤖 Updating OpenCode..."
hash -r 2>/dev/null || true
if command -v opencode >/dev/null 2>&1; then
    opencode upgrade
    echo "   ✅ OpenCode updated"
else
    echo "   ⚠️  OpenCode not installed, skipping"
fi
echo ""

# Update Cursor CLI
echo "🤖 Updating Cursor CLI..."
hash -r 2>/dev/null || true
if command -v cursor-agent >/dev/null 2>&1; then
    if cursor-agent update 2>&1; then
        echo "   ✅ Cursor CLI updated"
    else
        echo "   ⚠️  Cursor CLI update failed (may require authentication - try logging in first)"
    fi
else
    echo "   ⚠️  Cursor CLI not installed, skipping"
fi
echo ""

echo "✅ All AI agents have been updated!"
echo ""
echo "💡 Run 'make install' to regenerate and reinstall OCG templates and commands"
