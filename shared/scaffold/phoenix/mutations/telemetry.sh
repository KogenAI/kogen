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

python3 - "$TELEMETRY" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

patched = content.replace('use Supervisor\n  import', 'use Supervisor\n\n  import')

with open(path, 'w') as f:
    f.write(patched)
PYEOF

# Post-condition: assert blank line between `use Supervisor` and `import` is present after patching
if ! python3 -c "
import sys
content = open('$TELEMETRY').read()
sys.exit(0 if 'use Supervisor\n\n  import' in content else 1)
"; then
    echo "[telemetry.sh] ERROR: post-condition failed — blank line between 'use Supervisor' and 'import' not found in $TELEMETRY" >&2
    exit 1
fi

echo "[telemetry.sh] done"
