#!/usr/bin/env bash
# run-tests.sh — run all install round-trip tests under this directory.
# Each *_test.sh is hermetic (own tmp_home via mktemp, HOME override).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fails=0
files=()

while IFS= read -r -d '' f; do
    files+=("$f")
done < <(find "$HERE" -maxdepth 1 -name '*_test.sh' -type f -print0 2>/dev/null)

if [ "${#files[@]}" -eq 0 ]; then
    echo "install tests: no test files found under $HERE"
    exit 1
fi

for t in "${files[@]}"; do
    name="$(basename "$t")"
    out="$(bash "$t" 2>&1)"
    rc=$?
    echo "$out"
    summary="$(echo "$out" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -1)"
    if [ -n "$summary" ]; then
        echo "ok: $name — $summary"
    else
        if [ "$rc" -ne 0 ]; then
            echo "FAIL: $name — no summary line (exit $rc)"
            fails=$((fails + 1))
        else
            echo "ok: $name — (no summary)"
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        fails=$((fails + 1))
    fi
done

if [ "$fails" -gt 0 ]; then
    echo "install tests: $fails file(s) FAILED"
    exit 1
fi
echo "install tests: all PASS"
