#!/usr/bin/env bash
# data_case.sh — adds ~r"/data_case\.ex$" to OptimumCredo.Check.Readability.ImportOrder
#                excluded list in .credo.exs.
# Idempotent: skips if data_case exclusion already present.
#
# NOTE: belt-and-braces with .credo.exs.eex template bake.
# The template already ships with data_case excluded; this mutation is kept
# as a fallback in case the credo template diverges.
#
# Usage: data_case.sh <app_path> [--no-ecto]
#   --no-ecto  skip DataCase mutation entirely

set -euo pipefail

APP_PATH="$1"
shift

NO_ECTO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-ecto)
        NO_ECTO="1"
        shift
        ;;
    --with-appsignal)
        # Accepted but ignored by this mutation
        shift
        ;;
    --github-url)
        # Accepted but ignored; consumes next arg as value
        shift 2
        ;;
    *)
        shift
        ;;
    esac
done

# When --no-ecto is set, DataCase is not generated — skip mutation
if [[ -n "$NO_ECTO" ]]; then
    echo "[data_case.sh] --no-ecto set — skipping DataCase mutation"
    exit 0
fi

CREDO="$APP_PATH/.credo.exs"

if [ ! -f "$CREDO" ]; then
    echo "[data_case.sh] ERROR: $CREDO not found" >&2
    exit 1
fi

if ! grep -qF '/data_case\.ex$"' "$CREDO"; then
    python3 - "$CREDO" <<'PYEOF'
import sys
import re

credo_path = sys.argv[1]
with open(credo_path, 'r') as f:
    content = f.read()

# Anchor: the ImportOrder check's excluded list ends with channel_case entry
anchor = '~r"/channel_case\\.ex$"'
replacement = anchor + '\n                 ~r"/data_case\\.ex$"'
new_content = content.replace(anchor, replacement, 1)

with open(credo_path, 'w') as f:
    f.write(new_content)
PYEOF
fi

# Post-condition: data_case exclusion must be present
if ! grep -qF '/data_case\.ex$"' "$CREDO"; then
    echo "[data_case.sh] ERROR: post-condition failed — '/data_case\\.ex\$\"' not found after mutation (anchor: channel_case)" >&2
    exit 1
fi

echo "[data_case.sh] done"
