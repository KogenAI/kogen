#!/usr/bin/env bash
# telemetry.sh — adds blank line between `use Supervisor` and `import` in telemetry.ex.
# Idempotent: sed won't match if already patched (two newlines already present).
#
# Usage: telemetry.sh <app_path> <app_name>
#   app_name  snake_case (e.g. my_app)

set -euo pipefail

APP_PATH="$1"
APP_NAME="$2"

TELEMETRY="$APP_PATH/lib/${APP_NAME}_web/telemetry.ex"

if [ ! -f "$TELEMETRY" ]; then
    echo "[telemetry.sh] ERROR: $TELEMETRY not found" >&2
    exit 1
fi

# Replace "use Supervisor\n  import" with "use Supervisor\n\n  import"
# sed -i '' handles the macOS BSD sed; \n in replacement is literal newline via $'\n'
sed -i '' "s/use Supervisor$'\n'  import/use Supervisor$'\n'$'\n'  import/" "$TELEMETRY" 2>/dev/null || true

# BSD sed doesn't interpolate $'...' in -e expressions; use printf approach instead
python3 - "$TELEMETRY" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

patched = content.replace('use Supervisor\n  import', 'use Supervisor\n\n  import')

with open(path, 'w') as f:
    f.write(patched)
PYEOF

echo "[telemetry.sh] done"
