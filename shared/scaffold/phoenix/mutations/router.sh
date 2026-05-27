#!/usr/bin/env bash
# router.sh — appends health controller route inside the main scope block.
# Idempotent: skips if HealthController route already present.
#
# Usage: router.sh <app_path> <app_name_module>
#   app_name_module  CamelCase (e.g. MyApp)

set -euo pipefail

APP_PATH="$1"
APP_NAME_MODULE="$2"

ROUTER="$APP_PATH/lib/$(echo "$APP_NAME_MODULE" | tr '[:upper:]' '[:lower:]')_web/router.ex"

# Fallback: scan for the router file if naming differs
if [ ! -f "$ROUTER" ]; then
  # app slug may differ from module name due to camelization
  ROUTER="$(find "$APP_PATH/lib" -name "router.ex" -path "*_web*" | head -1)"
fi

if [ ! -f "$ROUTER" ]; then
  echo "[router.sh] ERROR: router.ex not found under $APP_PATH/lib" >&2
  exit 1
fi

HEALTH_ROUTE="  resources \"/health\", ${APP_NAME_MODULE}Web.HealthController, only: [:index]"

if ! grep -qF 'HealthController' "$ROUTER"; then
  # Append before the final `end` of the file
  sed -i '' "s|^end$|${HEALTH_ROUTE}\nend|" "$ROUTER"
fi

echo "[router.sh] done"
