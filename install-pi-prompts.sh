#!/usr/bin/env bash
# install-pi-prompts.sh — install pi-prompts/*.md to ~/.pi/agent/prompts/
# with checksum-stable cp (reuses content_stable_cp pattern from install-launchers.sh).
#
# Only installs document.md and split.md — does NOT touch rule.md, command.md,
# release-new-version.md or any other existing prompt files.
# Idempotent: re-run produces no diff when files are unchanged.

set -euo pipefail

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_SRC="$CODEGEN_DIR/templates/shared/pi-prompts"
PROMPTS_DST="$HOME/.pi/agent/prompts"

# content_stable_cp <src> <dst>
# Copies src to dst only when dst doesn't exist or its bytes differ from src.
content_stable_cp() {
    local src="$1"
    local dst="$2"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    cp "$src" "$dst"
}

if [ ! -d "$PROMPTS_DST" ]; then
    echo "WARNING: ~/.pi/agent/prompts/ does not exist — skipping pi prompt install" >&2
    echo "install-pi-prompts: SKIPPED (no ~/.pi/agent/prompts/)"
    exit 0
fi

echo "Installing Pi prompts into $PROMPTS_DST..."

content_stable_cp "$PROMPTS_SRC/document.md" "$PROMPTS_DST/document.md"
echo "   Installed: $PROMPTS_DST/document.md"

echo "install-pi-prompts: OK"
