#!/usr/bin/env bash
# gitignore.sh — appends Optimum dev/test sections to .gitignore.
# Idempotent: skips if "# Optimum development/test artifacts" section already present.
#
# Usage: gitignore.sh <app_path>

set -euo pipefail

APP_PATH="$1"
GITIGNORE="$APP_PATH/.gitignore"

if [ ! -f "$GITIGNORE" ]; then
    echo "[gitignore.sh] ERROR: $GITIGNORE not found" >&2
    exit 1
fi

if ! grep -qF '# Optimum development/test artifacts' "$GITIGNORE"; then
    cat >>"$GITIGNORE" <<'EOF'

# Optimum development/test artifacts
/node_modules/
/priv/plts/
/screenshots/
/package.json
/package-lock.json
.DS_Store
.env
/codegen/pitches/
EOF
fi

echo "[gitignore.sh] done"
