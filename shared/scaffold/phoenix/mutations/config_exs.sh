#!/usr/bin/env bash
# config_exs.sh — appends `import_config "#{config_env()}.exs"` to config/config.exs if absent.
# Idempotent: skips if the import_config line is already present.
#
# Usage: config_exs.sh <app_path>

set -euo pipefail

APP_PATH="$1"
CONFIG="$APP_PATH/config/config.exs"

if [ ! -f "$CONFIG" ]; then
    echo "[config_exs.sh] ERROR: $CONFIG not found" >&2
    exit 1
fi

if ! grep -qF 'import_config "#{config_env()' "$CONFIG"; then
    printf '\nimport_config "#{config_env()}.exs"\n' >>"$CONFIG"
fi

echo "[config_exs.sh] done"
