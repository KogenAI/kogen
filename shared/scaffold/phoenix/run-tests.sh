#!/usr/bin/env bash
# run-tests.sh — run all mutation unit tests + eex_render_test.sh in this scaffold dir.
# Mirrors harnesses/claude/hooks/run-tests.sh; runs each *_test.sh in parallel.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_pass=0
total_fail=0
any_fail=0

run_test() {
    local t="$1"
    local name
    name="$(basename "$t")"
    local out
    out="$(bash "$t" 2>&1)"
    local rc=$?
    # Extract pass/fail counts from last "N passed, N failed" line
    local summary
    summary="$(echo "$out" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -1)"
    if [ -n "$summary" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "$out"
            echo "FAIL: $name — $summary"
        else
            echo "ok: $name — $summary"
        fi
    else
        echo "$out"
        if [ "$rc" -ne 0 ]; then
            echo "FAIL: $name — no summary line (exit $rc)"
        else
            echo "ok: $name — (no summary)"
        fi
    fi
    return $rc
}

fails=0
files=()

# Collect mutation tests
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(find "$HERE/mutations" -maxdepth 1 -name '*_test.sh' -type f -print0 2>/dev/null)

# Collect eex_render_test.sh
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(find "$HERE" -maxdepth 1 -name 'eex_render_test.sh' -type f -print0 2>/dev/null)

if [ "${#files[@]}" -eq 0 ]; then
    echo "scaffold mutation tests: no test files found under $HERE"
    exit 1
fi

for t in "${files[@]}"; do
    run_test "$t" || fails=$((fails + 1))
done

if [ "$fails" -gt 0 ]; then
    echo "scaffold mutation tests: $fails file(s) FAILED"
    exit 1
fi
echo "scaffold mutation tests: all PASS"
