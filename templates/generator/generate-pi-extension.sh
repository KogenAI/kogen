#!/bin/bash
# generate-pi-extension.sh — Build Pi enforcement extension TypeScript package.
#
# Usage: bash templates/generator/generate-pi-extension.sh [<pi-extension-dir>]
#
# <pi-extension-dir> defaults to templates/shared/pi-extensions/enforcement
# relative to this script's parent (templates/).
#
# Steps:
#   1. npm install --omit=dev (install production deps only, skip devDeps for build)
#      Then install devDeps too for compilation.
#   2. npx tsc  (compile TypeScript → dist/)
#   3. node scripts/emit-handlers.js  (emit dist/handlers.json)
#
# On success prints: "generate-pi-extension: OK"
# On failure prints error message and exits non-zero.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")"

# Resolve pi-extension-dir from first arg or default
if [ -n "$1" ]; then
    PI_EXTENSION_DIR="$1"
else
    PI_EXTENSION_DIR="$(dirname "$TEMPLATES_DIR")/harnesses/pi/pi-extensions/enforcement"
fi

if [ ! -d "$PI_EXTENSION_DIR" ]; then
    echo "ERROR: generate-pi-extension.sh: Pi extension directory not found: $PI_EXTENSION_DIR" >&2
    exit 1
fi

if [ ! -f "$PI_EXTENSION_DIR/package.json" ]; then
    echo "ERROR: generate-pi-extension.sh: No package.json found in $PI_EXTENSION_DIR" >&2
    exit 1
fi

echo "generate-pi-extension: building $PI_EXTENSION_DIR"

cd "$PI_EXTENSION_DIR"

# Install all deps (including devDeps for TypeScript compiler)
echo "  npm install..."
mise exec -- npm install --silent

# Compile TypeScript
echo "  npx tsc..."
mise exec -- npx tsc

# Emit handlers.json from compiled output
echo "  emit-handlers..."
mise exec -- node scripts/emit-handlers.js

echo "generate-pi-extension: OK"
