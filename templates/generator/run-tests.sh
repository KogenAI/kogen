#!/usr/bin/env bash
# run-tests.sh — run every *_test.sh generator test in parallel, then Python unittest.
#
# Each test script is hermetic (own tmp dirs, isolated CODEGEN_DIR), so xargs
# -P parallelism is safe. Job count caps at 8 to avoid thrashing on smaller
# machines.
#
# After the bash leg, runs python3 -m unittest discover -s tests -v.
# Exit 1 if either leg fails; else exit 0.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

bash_rc=0

# Collect *_test.sh files + the legacy-named test_dual_render.sh (test_*.sh prefix).
{
    find "$SCRIPT_DIR" -name '*_test.sh' -type f -print0
    # Include test_dual_render.sh explicitly (named test_*.sh, not *_test.sh).
    [ -f "$SCRIPT_DIR/test_dual_render.sh" ] && printf '%s\0' "$SCRIPT_DIR/test_dual_render.sh"
} | xargs -0 -n1 -P"$JOBS" -I{} bash -c 'run_one "$@"' _ {} || bash_rc=1

# ── Python unittest leg ───────────────────────────────────────────────────────

py_out=$(cd "$SCRIPT_DIR" && python3 -m unittest discover -s tests -v 2>&1)
py_rc=$?

if [ "$py_rc" -eq 0 ]; then
    # Extract test count from unittest output (e.g. "Ran 61 tests in 0.025s")
    py_summary=$(printf '%s' "$py_out" | grep -E "^Ran [0-9]+ test" | tail -1 || echo "")
    printf 'ok:   python-unittest — %s\n' "$py_summary"
else
    printf 'FAIL: python-unittest\n%s\n' "$py_out"
fi

if [ "$bash_rc" -ne 0 ] || [ "$py_rc" -ne 0 ]; then
    exit 1
fi
exit 0
