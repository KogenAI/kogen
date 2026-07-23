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

# Update pi — converge to the version pinned in harnesses/pi/manifest.yaml
# runtime.package/runtime.version (single authority; no latest-version
# fallback). Missing/mismatched version after the attempt is a fail-loud
# error, not a warn-and-skip.
echo "🤖 Updating pi..."
hash -r 2>/dev/null || true
pi_pkg=$(yq -r '.runtime.package' "$CODEGEN_DIR/harnesses/pi/manifest.yaml")
pi_ver=$(yq -r '.runtime.version' "$CODEGEN_DIR/harnesses/pi/manifest.yaml")
if command -v pi >/dev/null 2>&1; then
    current_pi=$(pi --version 2>/dev/null | tr -d '[:space:]')
else
    current_pi=""
fi
if [ "$current_pi" = "$pi_ver" ]; then
    echo "   ✅ pi already at pinned version ($pi_ver)"
else
    echo "   ⬆️  Converging pi ${current_pi:-<not installed>} → ${pi_ver}"
    npm install -g "${pi_pkg}@${pi_ver}"
    hash -r 2>/dev/null || true
    new_pi=$(pi --version 2>/dev/null | tr -d '[:space:]')
    if [ "$new_pi" != "$pi_ver" ]; then
        echo "   ❌ pi version mismatch after update: got '${new_pi:-<none>}', pinned '${pi_ver}'" >&2
        exit 1
    fi
    echo "   ✅ pi updated to ${pi_ver}"
fi
echo ""

echo "✅ All AI agents have been updated (Claude Code + pi)!"
echo ""
echo "💡 Run 'make install' to regenerate and reinstall OCG templates and commands"
