#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$SCRIPT_DIR/../../pi/pi-jsonl-filter.cjs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '%s\n' \
    '{"type":"message_update","text":"cumulative"}' \
    '{"type":"tool_execution_end","toolName":"bash"}' \
    'native stderr warning' \
    '{"type":"agent_end","messages":[{"content":"done"}]}' \
    >"$TMP_DIR/input.jsonl"

if node "$FILTER" <"$TMP_DIR/input.jsonl" >"$TMP_DIR/output.jsonl"; then
    :
else
    printf 'FAIL: filter exited non-zero\n' >&2
    exit 1
fi

if grep -qF 'message_update' "$TMP_DIR/output.jsonl"; then
    printf 'FAIL: cumulative message_update survived\n' >&2
    exit 1
fi

grep -qF 'tool_execution_end' "$TMP_DIR/output.jsonl"
grep -qF 'native stderr warning' "$TMP_DIR/output.jsonl"
grep -qF 'agent_end' "$TMP_DIR/output.jsonl"

# CRLF and unterminated final records must survive byte-for-byte; readline
# normalizes both, so this catches regressions to line-oriented filtering.
printf '{"type":"message_update"}\r\nwarning\r\n{"type":"agent_end"}' >"$TMP_DIR/bytes-input.jsonl"
printf 'warning\r\n{"type":"agent_end"}' >"$TMP_DIR/bytes-expected.jsonl"
node "$FILTER" <"$TMP_DIR/bytes-input.jsonl" >"$TMP_DIR/bytes-output.jsonl"
if ! cmp -s "$TMP_DIR/bytes-expected.jsonl" "$TMP_DIR/bytes-output.jsonl"; then
    printf 'FAIL: filter changed retained CRLF or unterminated bytes\n' >&2
    exit 1
fi

# A broken downstream capture must make the filter fail loudly rather than
# silently reporting a partial durable stream as complete.
mkfifo "$TMP_DIR/filter-failure.fifo"
printf 'first\n%*s\n' 131072 '' >"$TMP_DIR/filter-failure-input.jsonl"
(
    IFS= read -r _ <"$TMP_DIR/filter-failure.fifo" || true
) &
reader_pid=$!
set +e
node "$FILTER" <"$TMP_DIR/filter-failure-input.jsonl" >"$TMP_DIR/filter-failure.fifo" 2>"$TMP_DIR/filter-failure.err"
filter_failure_code=$?
wait "$reader_pid"
set -e

if [[ "$filter_failure_code" -eq 0 ]] || ! grep -qF 'Pi stream filter failed' "$TMP_DIR/filter-failure.err"; then
    printf 'FAIL: downstream write failure did not fail loudly (exit %s): %s\n' \
        "$filter_failure_code" "$(<"$TMP_DIR/filter-failure.err")" >&2
    exit 1
fi

printf '3 passed, 0 failed\n'
