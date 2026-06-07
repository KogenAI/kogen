#!/usr/bin/env bash
# router.sh — appends health controller route inside the main scope "/" block.
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

HEALTH_ROUTE="    get \"/health\", ${APP_NAME_MODULE}Web.HealthController, :index"

if ! grep -qF 'HealthController' "$ROUTER"; then
    # Insert health route before the closing `end` of the first `scope "/"` block.
    # The anchor is `pipe_through :browser` which appears inside the scope "/" block.
    python3 - "$ROUTER" "$HEALTH_ROUTE" <<'PYEOF'
import sys
import re

router_path = sys.argv[1]
health_route = sys.argv[2]

with open(router_path, 'r') as f:
    content = f.read()

# Find the scope "/" block and insert health route before the closing `end`
# Pattern: scope "/" block contains `pipe_through :browser`
# Insert health_route before the `end` that closes the first scope block
def insert_health_route(content, health_route):
    lines = content.split('\n')
    # Find the scope "/" line
    scope_idx = None
    for i, line in enumerate(lines):
        if 'scope "/"' in line or "scope '/'," in line:
            scope_idx = i
            break

    if scope_idx is None:
        return None

    # Find the matching end (counting scope/do/end pairs from scope_idx)
    depth = 0
    end_idx = None
    for i in range(scope_idx, len(lines)):
        line = lines[i].strip()
        # Count opening do blocks
        if line.endswith(' do') or line == 'do' or ' do' in line:
            depth += 1
        # Count ends
        if line == 'end':
            depth -= 1
            if depth == 0:
                end_idx = i
                break

    if end_idx is None:
        return None

    # Insert the health route before the end
    new_lines = lines[:end_idx] + [health_route, ''] + lines[end_idx:]
    # Clean up double blank lines before end
    result = '\n'.join(new_lines)
    result = re.sub(r'\n{3,}(\s*end)', r'\n\n\1', result)
    return result

new_content = insert_health_route(content, health_route)
if new_content is None:
    print("[router.sh] ERROR: could not find scope \"/\" block to insert health route", file=sys.stderr)
    sys.exit(1)

with open(router_path, 'w') as f:
    f.write(new_content)
PYEOF
fi

# Post-condition: health route must be present
if ! grep -qF 'HealthController' "$ROUTER"; then
    echo "[router.sh] FAILED: /health route not inserted" >&2
    exit 1
fi

echo "[router.sh] done"
