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
# Two modes, ONE predicate. `--prune` deletes exactly the files the default
# check mode would fail on, so the gate and its remedy can never disagree
# about what an orphan is. `make install` runs --prune right after the
# compiler, which is what makes "delete a registry id" a complete action: the
# generated hook that backed it disappears with it, instead of surviving on
# disk (still firing fleet-wide) until someone reads a red gate and works out
# that the fix is an `rm` no tool performs for them.
#
# Usage:
#   orphan-hook-check.sh --hooks-dir DIR --registry FILE [--prune]
# Exit: 0 = no orphans (or all pruned); 1 = orphan(s) found; 2 = usage/yq error.

set -euo pipefail

HOOKS_DIR=""
REGISTRY=""
PRUNE=0

while [ $# -gt 0 ]; do
    case "$1" in
    --prune)
        PRUNE=1
        shift
        ;;
    --hooks-dir)
        HOOKS_DIR="$2"
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
            if [ "$PRUNE" -eq 1 ]; then
                rm -f "$f"
                echo "orphan-hook-check: PRUNED $f (no live registry id '$id')"
            else
                echo "enforce-registry-parity: ORPHAN $f (no live registry id '$id') — its registry id was deleted or renamed but the generated file was left on disk, where hook_registrations.py still registers it from a filesystem glob. Run 'make install' (which prunes it) or delete the file."
                fail=1
            fi
        fi
    done
}

check_dir "$HOOKS_DIR" sh

[ "$fail" -eq 0 ] && [ -n "${VERBOSE:-}" ] && echo "orphan-hook-check: PASS" || true
exit "$fail"
