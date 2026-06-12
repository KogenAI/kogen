#!/usr/bin/env bash
# formatter_exs.sh — adds DoctestFormatter and Phoenix.LiveView.HTMLFormatter to .formatter.exs plugins.
# Idempotent: skips if DoctestFormatter already present.
#
# Usage: formatter_exs.sh <app_path> [--no-ecto]
#   --no-ecto  also strip :ecto, :ecto_sql from import_deps and remove migrations subdirectory

set -euo pipefail

APP_PATH="$1"
NO_ECTO=""

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-ecto)
        NO_ECTO="1"
        shift
        ;;
    *)
        echo "[formatter_exs.sh] Unknown argument: $1" >&2
        exit 1
        ;;
    esac
done

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

# --no-ecto: strip :ecto and :ecto_sql from import_deps, remove migrations subdirectory line
if [[ -n "$NO_ECTO" ]]; then
    # Remove :ecto, and :ecto_sql, atoms (with optional trailing comma/space) from import_deps line
    python3 - "$FORMATTER" <<'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Strip :ecto and :ecto_sql atoms from import_deps (handles any ordering, trailing commas)
# Pattern covers `:ecto,` `:ecto_sql,` `, :ecto` `, :ecto_sql` with optional spaces
content = re.sub(r':ecto_sql,?\s*', '', content)
content = re.sub(r':ecto,?\s*', '', content)
# Remove trailing comma left before closing bracket: [, :phoenix] -> [:phoenix]
content = re.sub(r'\[\s*,\s*', '[', content)
# Remove leading comma before closing bracket: [:phoenix, ] -> [:phoenix]
content = re.sub(r',\s*\]', ']', content)

# Remove the subdirectories: ["priv/*/migrations"] line entirely
lines = content.split('\n')
lines = [l for l in lines if 'subdirectories:' not in l or 'migrations' not in l]
content = '\n'.join(lines)

with open(path, 'w') as f:
    f.write(content)
PYEOF

    # Post-condition: no ecto/ecto_sql atoms in import_deps
    if grep -qE ':(ecto|ecto_sql)' "$FORMATTER"; then
        echo "[formatter_exs.sh] ERROR: --no-ecto post-condition failed — :ecto or :ecto_sql still present" >&2
        exit 1
    fi

    # Post-condition: no migrations subdirectory line
    if grep -q 'subdirectories.*migrations' "$FORMATTER"; then
        echo "[formatter_exs.sh] ERROR: --no-ecto post-condition failed — migrations subdirectories line still present" >&2
        exit 1
    fi
fi

echo "[formatter_exs.sh] done"
