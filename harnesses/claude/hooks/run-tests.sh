#!/usr/bin/env bash
# run-tests.sh — run every *_test.sh hook unit-test script in parallel.
#
# Each test script is hermetic (own tmp dirs, no shared global state), so xargs
# -P parallelism is safe. Job count caps at 8 to avoid thrashing on smaller
# machines.

set -u

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-8}"

run_one() {
    local t="$1"
    local name
    name="$(basename "$t")"
    local out
    out=$(bash "$t" 2>&1)
    local last
    last=$(printf '%s' "$out" | grep -E "passed, [0-9]+ failed" | tail -1)
    if printf '%s' "$last" | grep -qE "failed [1-9]"; then
        printf 'FAIL: %s — %s\n%s\n' "$name" "$last" "$out"
        return 1
    fi
    printf 'ok:   %s — %s\n' "$name" "$last"
}

export -f run_one

find "$HOOKS_DIR" -name '*_test.sh' -type f -print0 |
    xargs -0 -n1 -P"$JOBS" -I{} bash -c 'run_one "$@"' _ {}
