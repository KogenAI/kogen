#!/usr/bin/env bash
# install-launchers.sh — install claude-{build,debug,design} and codex-{build,inspector,design}
# into $HOME/.local/bin with checksum-stable cp (reuses content_stable_cp from install.sh).
#
# Invoked by Makefile `install` target after install.sh completes. Idempotent.
# Strip .sh extension in dest (e.g. codex-build.sh → codex-build).

set -euo pipefail

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"

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

mkdir -p "$INSTALL_DIR"

install_launcher() {
    local src="$1"
    local dest_name="$2"
    local dest="$INSTALL_DIR/$dest_name"
    content_stable_cp "$src" "$dest"
    chmod +x "$dest"
    echo "   Installed: $dest"
}

echo "Installing launchers into $INSTALL_DIR..."

# Claude trio
install_launcher "$CODEGEN_DIR/templates/shared/claude-build.sh"  "claude-build"
install_launcher "$CODEGEN_DIR/templates/shared/claude-debug.sh"  "claude-debug"
install_launcher "$CODEGEN_DIR/templates/shared/claude-design.sh" "claude-design"

# Codex trio
install_launcher "$CODEGEN_DIR/templates/shared/codex-build.sh"     "codex-build"
install_launcher "$CODEGEN_DIR/templates/shared/codex-inspector.sh" "codex-inspector"
install_launcher "$CODEGEN_DIR/templates/shared/codex-design.sh"    "codex-design"

echo "install-launchers: OK"
