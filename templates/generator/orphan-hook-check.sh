#!/usr/bin/env bash
# orphan-hook-check.sh — reverse parity: fail if a committed, fully-generated
# enforcement hook file has no live `generated: true` id in registry.yaml.
#
# Forward parity (Makefile enforce-registry-parity) catches DRIFT and
# MISSING-committed. This catches the reverse: a committed .sh/.ts whose
# registry id was deleted/renamed but whose file was left on disk — it keeps
# firing fleet-wide with no registry backing (hook_registrations.py registers
# every *.sh from a filesystem glob, registry-independent).
#
# Discriminator: the FULL-GENERATION follow-up line
#   "Edit registry.yaml and run `make install` to regenerate."
# (NOT the bare "GENERATED FROM" marker — that is injected by
# hook_registrations.py --emit-headers into EVERY manifest header, incl.
# hand-authored hooks, and would false-positive ~50 files.)
#
# Usage:
#   orphan-hook-check.sh --hooks-dir DIR --ts-dir DIR --registry FILE
# Exit: 0 = no orphans; 1 = orphan(s) found; 2 = usage/yq error.

set -euo pipefail

HOOKS_DIR=""
TS_DIR=""
REGISTRY=""

while [ $# -gt 0 ]; do
    case "$1" in
    --hooks-dir)
        HOOKS_DIR="$2"
        shift 2
        ;;
    --ts-dir)
        TS_DIR="$2"
        shift 2
        ;;
    --registry)
        REGISTRY="$2"
        shift 2
        ;;
    *)
        echo "orphan-hook-check: unknown arg: $1" >&2
        exit 2
        ;;
    esac
done

[ -n "$REGISTRY" ] && [ -f "$REGISTRY" ] || {
    echo "orphan-hook-check: --registry FILE required" >&2
    exit 2
}
command -v yq >/dev/null 2>&1 || {
    echo "orphan-hook-check: yq not found on PATH" >&2
    exit 2
}

# Discriminator substring (literal; present in both .sh '#' and .ts ' *' headers).
MARKER="Edit registry.yaml and run"

# Live generated ids (any kind with generated: true). Newline-separated.
LIVE_IDS=$(yq '.[] | select(.generated == true) | .id' "$REGISTRY")

is_live() {
    # POSIX-safe membership test on newline list.
    printf '%s\n' "$LIVE_IDS" | grep -qxF "$1"
}

fail=0

check_dir() {
    local dir="$1" ext="$2"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    for f in "$dir"/*."$ext"; do
        [ -f "$f" ] || continue
        grep -qF "$MARKER" "$f" || continue # only fully-generated files
        local base id
        base=$(basename "$f")
        id="${base%.$ext}"
        if ! is_live "$id"; then
            echo "enforce-registry-parity: ORPHAN $f (no live registry id '$id')"
            fail=1
        fi
    done
}

check_dir "$HOOKS_DIR" sh
check_dir "$TS_DIR" ts

[ "$fail" -eq 0 ] && [ -n "${VERBOSE:-}" ] && echo "orphan-hook-check: PASS" || true
exit "$fail"
