#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CLAUDE_CONFIG="$HOME/.claude.json"
BACKUP_FILE="$HOME/.claude.json.backup-$(date +%Y%m%d_%H%M%S)"

if [ ! -f "$CLAUDE_CONFIG" ]; then
    echo "ℹ️  No ~/.claude.json file found"
    exit 0
fi

echo "🔍 Analyzing Claude Code history..."
echo ""

ORIGINAL_SIZE=$(du -h "$CLAUDE_CONFIG" | cut -f1)
TOTAL_PROJECTS=$(jq '.projects | length' "$CLAUDE_CONFIG")

echo "📊 Current state:"
echo "   File size: $ORIGINAL_SIZE"
echo "   Total projects: $TOTAL_PROJECTS"

WORKSPACE_COUNT=$(jq '.projects | keys | map(select(contains("/codegen/workspaces/"))) | length' "$CLAUDE_CONFIG")
PROJECTS_WITH_HISTORY=$(jq '[.projects[] | select(.history != null and (.history | length) > 0)] | length' "$CLAUDE_CONFIG")

echo "   Workspace entries: $WORKSPACE_COUNT"
echo "   Projects with history: $PROJECTS_WITH_HISTORY"
echo ""

if [ "$WORKSPACE_COUNT" -eq 0 ] && [ "$PROJECTS_WITH_HISTORY" -eq 0 ]; then
    echo "✅ Nothing to prune"
    exit 0
fi

if [ "$WORKSPACE_COUNT" -gt 0 ]; then
    echo "🗑️  Workspace entries to remove:"
    jq -r '.projects | keys | map(select(contains("/codegen/workspaces/"))) | .[]' "$CLAUDE_CONFIG" | sed 's/^/   - /'
    echo ""
fi

if [ "$PROJECTS_WITH_HISTORY" -gt 0 ]; then
    echo "🧹 Will clear history from ALL projects (images cause massive bloat)"
    echo ""
fi

read -p "⚠️  Remove workspace entries and clear all project history? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Operation cancelled"
    exit 1
fi

echo "💾 Creating backup: $BACKUP_FILE"
cp "$CLAUDE_CONFIG" "$BACKUP_FILE"

echo "🧹 Removing workspace entries and clearing history..."

# Use Python to safely clean up
python3 <<EOF
import json
import sys
import os

try:
    config_path = os.path.expanduser('~/.claude.json')
    with open(config_path, 'r') as f:
        data = json.load(f)

    # Remove all workspace entries
    workspace_keys = [k for k in data['projects'].keys() if '/codegen/workspaces/' in k]
    for key in workspace_keys:
        del data['projects'][key]

    # Clear history from ALL remaining projects (images cause bloat)
    for project in data['projects'].values():
        if 'history' in project:
            project['history'] = []

    # Write back
    with open(config_path, 'w') as f:
        json.dump(data, f, indent=2)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [ $? -ne 0 ]; then
    echo "❌ Failed to clean up"
    echo "   Restoring from backup: $BACKUP_FILE"
    cp "$BACKUP_FILE" "$CLAUDE_CONFIG"
    exit 1
fi

NEW_SIZE=$(du -h "$CLAUDE_CONFIG" | cut -f1)
NEW_TOTAL=$(jq '.projects | length' "$CLAUDE_CONFIG")

echo ""
echo "✅ Cleanup complete!"
echo "   Before: $ORIGINAL_SIZE ($TOTAL_PROJECTS projects)"
echo "   After: $NEW_SIZE ($NEW_TOTAL projects)"
echo "   Removed: $WORKSPACE_COUNT workspace entries"
echo "   Cleared: History from $PROJECTS_WITH_HISTORY projects"
echo "   Backup: $BACKUP_FILE"
