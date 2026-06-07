#!/usr/bin/env bash
# formatter_exs.sh — adds DoctestFormatter and Phoenix.LiveView.HTMLFormatter to .formatter.exs plugins.
# Idempotent: skips if DoctestFormatter already present.
#
# Usage: formatter_exs.sh <app_path>

set -euo pipefail

APP_PATH="$1"
FORMATTER="$APP_PATH/.formatter.exs"

if [ ! -f "$FORMATTER" ]; then
    echo "[formatter_exs.sh] ERROR: $FORMATTER not found" >&2
    exit 1
fi

if ! grep -qF 'DoctestFormatter' "$FORMATTER"; then
    # Replace existing Phoenix.LiveView.HTMLFormatter (or nothing) with both plugins
    sed 's/Phoenix\.LiveView\.HTMLFormatter/DoctestFormatter, Phoenix.LiveView.HTMLFormatter/' "$FORMATTER" >"${FORMATTER}.tmp" && mv "${FORMATTER}.tmp" "$FORMATTER"
fi

# Post-condition: DoctestFormatter must be present
if ! grep -qF 'DoctestFormatter' "$FORMATTER"; then
    echo "[formatter_exs.sh] ERROR: post-condition failed — 'DoctestFormatter' not found after substitution (anchor: Phoenix.LiveView.HTMLFormatter)" >&2
    exit 1
fi

echo "[formatter_exs.sh] done"
