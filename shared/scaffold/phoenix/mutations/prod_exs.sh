#!/usr/bin/env bash
# prod_exs.sh — creates config/prod.exs with `import Config` if absent.
# Idempotent: no-op if file already exists.
#
# Usage: prod_exs.sh <app_path>

set -euo pipefail

APP_PATH="$1"
PROD_CONFIG="$APP_PATH/config/prod.exs"

if [ ! -f "$PROD_CONFIG" ]; then
    mkdir -p "$(dirname "$PROD_CONFIG")"
    printf 'import Config\n' >"$PROD_CONFIG"
fi

echo "[prod_exs.sh] done"
