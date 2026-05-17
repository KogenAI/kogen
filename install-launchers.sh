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

# Remove legacy design binaries (idempotent)
for legacy in claude-design codex-design pi-design; do
    [ -f "$INSTALL_DIR/$legacy" ] && rm -f "$INSTALL_DIR/$legacy" && echo "   Removed legacy: $INSTALL_DIR/$legacy" || true
done

# Claude launchers
install_launcher "$CODEGEN_DIR/templates/shared/claude-build.sh" "claude-build"
install_launcher "$CODEGEN_DIR/templates/shared/claude-debug.sh" "claude-debug"
install_launcher "$CODEGEN_DIR/templates/shared/claude-shape.sh" "claude-shape"
install_launcher "$CODEGEN_DIR/templates/shared/claude-refactor.sh" "claude-refactor"

# Codex launchers
install_launcher "$CODEGEN_DIR/templates/shared/codex-build.sh" "codex-build"
install_launcher "$CODEGEN_DIR/templates/shared/codex-inspector.sh" "codex-inspector"
install_launcher "$CODEGEN_DIR/templates/shared/codex-shape.sh" "codex-shape"
install_launcher "$CODEGEN_DIR/templates/shared/codex-refactor.sh" "codex-refactor"

# Pi launchers
install_launcher "$CODEGEN_DIR/templates/shared/pi-build.sh" "pi-build"
install_launcher "$CODEGEN_DIR/templates/shared/pi-inspector.sh" "pi-inspector"
install_launcher "$CODEGEN_DIR/templates/shared/pi-shape.sh" "pi-shape"
install_launcher "$CODEGEN_DIR/templates/shared/pi-refactor.sh" "pi-refactor"

# zsh completion files
ZSH_COMPLETION_DIRS=(
    "/opt/homebrew/share/zsh/site-functions"
    "$HOME/.zsh/completions"
)
ZSH_COMPLETION_DST=""
for d in "${ZSH_COMPLETION_DIRS[@]}"; do
    if [ -d "$d" ] && [ -w "$d" ]; then
        ZSH_COMPLETION_DST="$d"
        break
    fi
done
if [ -n "$ZSH_COMPLETION_DST" ]; then
    for comp in _claude-shape _claude-refactor _claude-build; do
        content_stable_cp "$CODEGEN_DIR/templates/shared/$comp" "$ZSH_COMPLETION_DST/$comp"
        echo "   Installed zsh completion: $ZSH_COMPLETION_DST/$comp"
    done
else
    echo "WARNING: no writable zsh completion dir found (tried ${ZSH_COMPLETION_DIRS[*]}); skipping completion install" >&2
fi

echo "install-launchers: OK"
