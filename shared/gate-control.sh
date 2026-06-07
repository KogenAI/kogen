#!/usr/bin/env bash
# Thin wrapper — delegates to the harness gate-control lib.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$SCRIPT_DIR/../harnesses/claude/hooks/lib/gate-control.sh" "$@"
