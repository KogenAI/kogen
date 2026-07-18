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

out_dir="$(mktemp -d -t install-run-tests-XXXXXX)"
trap 'rm -rf "$out_dir"' EXIT

pids=()
names=()
for t in "${files[@]}"; do
    name="$(basename "$t")"
    (bash "$t" >"$out_dir/$name.out" 2>&1) &
    pids+=("$!")
    names+=("$name")
done

for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    name="${names[$i]}"
    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi
    out="$(cat "$out_dir/$name.out")"
    summary="$(echo "$out" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -1)"
    if [ -n "$summary" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "$out"
            echo "FAIL: $name — $summary"
            fails=$((fails + 1))
        else
            if [ -n "${VERBOSE:-}" ]; then
                echo "ok: $name — $summary"
            fi
        fi
    else
        echo "$out"
        if [ "$rc" -ne 0 ]; then
            echo "FAIL: $name — no summary line (exit $rc)"
            fails=$((fails + 1))
        else
            if [ -n "${VERBOSE:-}" ]; then
                echo "ok: $name — (no summary)"
            fi
        fi
    fi
done

if [ "$fails" -gt 0 ]; then
    echo "install tests: $fails file(s) FAILED"
    exit 1
fi
if [ -n "${VERBOSE:-}" ]; then
    echo "install tests: all PASS"
fi
