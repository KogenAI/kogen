#!/usr/bin/env bash
# endpoint.sh — inserts Tidewave plug block after `use Phoenix.Endpoint, otp_app: :<app>`.
# Idempotent: skips if `plug Tidewave` already present.
#
# Usage: endpoint.sh <app_path> <app_name>
#   app_name  snake_case (e.g. my_app)

set -euo pipefail

APP_PATH="$1"
APP_NAME="$2"

ENDPOINT="$APP_PATH/lib/${APP_NAME}_web/endpoint.ex"

if [ ! -f "$ENDPOINT" ]; then
  echo "[endpoint.sh] ERROR: $ENDPOINT not found" >&2
  exit 1
fi

if ! grep -qF 'plug Tidewave' "$ENDPOINT"; then
  python3 - "$ENDPOINT" "$APP_NAME" << 'PYEOF'
import sys
import re

endpoint_path = sys.argv[1]
app_name = sys.argv[2]

with open(endpoint_path, 'r') as f:
    content = f.read()

tidewave_block = (
    '\n'
    '  if Code.ensure_loaded?(Tidewave) do\n'
    '    plug Tidewave\n'
    '  end'
)

anchor = f'use Phoenix.Endpoint, otp_app: :{app_name}'

if anchor in content:
    new_content = content.replace(anchor, anchor + tidewave_block, 1)
    with open(endpoint_path, 'w') as f:
        f.write(new_content)
else:
    print(f'[endpoint.sh] WARNING: could not find anchor "{anchor}" — skipping Tidewave plug')
PYEOF
fi

echo "[endpoint.sh] done"
