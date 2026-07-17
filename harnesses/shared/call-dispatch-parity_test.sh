#!/usr/bin/env bash
# call-dispatch-parity_test.sh — structural parity between
# harnesses/claude/call-dispatch.sh and harnesses/pi/call-dispatch.sh.
#
# The two legs are independent implementations of the same CODEGEN_CALL_*
# contract (no shared lib). This test does NOT assert byte-identity — the
# legs have known, documented asymmetries (claude's --resume/--session-id
# precedence vs pi's --session-id-creates-or-resumes; claude's
# CODEGEN_CALL_AGENTS_PATH is claude-only inline agent-def JSON). It asserts
# the parts that MUST stay identical: the CODEGEN_CALL_* env-var read set
# (minus the documented claude-only exception) and the JSON envelope's
# top-level key set (both `result` and `usage` sub-objects).
#
# Tests:
#   Test 1 (live) — every CODEGEN_CALL_* var read by the claude leg is also
#       read by the pi leg, except the documented claude-only exception
#       (CODEGEN_CALL_AGENTS_PATH).
#   Test 2 (live) — every CODEGEN_CALL_* var read by the pi leg is also read
#       by the claude leg (reverse direction — catches a pi-only var nobody
#       documented as an asymmetry).
#   Test 3 (live) — both legs' final envelope jq programs declare the same
#       top-level key set: result, usage, error, harness, session_id
#       (+ optional metrics on both).
#   Test 4 (live) — both legs' `result` sub-object declares the same key set:
#       status, value, reason, retry_meta.
#   Test 5 (live) — both legs' `usage` sub-object declares the same key set.
#
# Usage: bash call-dispatch-parity_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLAUDE_LEG="$CODEGEN_DIR/harnesses/claude/call-dispatch.sh"
PI_LEG="$CODEGEN_DIR/harnesses/pi/call-dispatch.sh"

# Documented per-harness-only vars — genuine asymmetries, not drift:
#   CODEGEN_CALL_AGENTS_PATH        — claude-only inline agent-def JSON
#   CODEGEN_CALL_JSON_SCHEMA_PATH   — claude-only (claude reads schema from a
#                                     file path; pi only takes inline content
#                                     via CODEGEN_CALL_JSON_SCHEMA)
#   CODEGEN_CALL_SETTINGS_PATH      — claude-only (claude --settings flag has
#                                     no pi equivalent)
CLAUDE_ONLY_VARS=(CODEGEN_CALL_AGENTS_PATH CODEGEN_CALL_JSON_SCHEMA_PATH CODEGEN_CALL_SETTINGS_PATH)

# CODEGEN_CALL_EXTENSION_PATH — pi-only (pi loads a TS extension by path;
# claude has no equivalent concept).
PI_ONLY_VARS=(CODEGEN_CALL_EXTENSION_PATH)

is_pi_only() {
    local v="$1"
    for x in "${PI_ONLY_VARS[@]}"; do
        [ "$x" = "$v" ] && return 0
    done
    return 1
}

pass=0
fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "0" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: $desc"
        fail=$((fail + 1))
    fi
}

extract_call_vars() {
    grep -oE 'CODEGEN_CALL_[A-Z_]+' "$1" | sort -u
}

is_claude_only() {
    local v="$1"
    for x in "${CLAUDE_ONLY_VARS[@]}"; do
        [ "$x" = "$v" ] && return 0
    done
    return 1
}

test_claude_vars_in_pi() {
    local claude_vars missing=""
    claude_vars=$(extract_call_vars "$CLAUDE_LEG")
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        is_claude_only "$v" && continue
        grep -qF "$v" "$PI_LEG" || missing="${missing}${missing:+, }$v"
    done <<<"$claude_vars"

    if [ -z "$missing" ]; then
        assert_true "claude CODEGEN_CALL_* vars all present in pi leg (minus documented exceptions)" 0
    else
        echo "  missing in pi leg: $missing"
        assert_true "claude CODEGEN_CALL_* vars all present in pi leg (minus documented exceptions)" 1
    fi
}

test_pi_vars_in_claude() {
    local pi_vars missing=""
    pi_vars=$(extract_call_vars "$PI_LEG")
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        is_pi_only "$v" && continue
        grep -qF "$v" "$CLAUDE_LEG" || missing="${missing}${missing:+, }$v"
    done <<<"$pi_vars"

    if [ -z "$missing" ]; then
        assert_true "pi CODEGEN_CALL_* vars all present in claude leg" 0
    else
        echo "  undocumented pi-only vars (missing in claude leg): $missing"
        assert_true "pi CODEGEN_CALL_* vars all present in claude leg" 1
    fi
}

# Extracts the top-level jq object key set from the FINAL envelope-building
# `jq -n ... '{ ... }'` block in a call-dispatch.sh file (the one that emits
# `harness:` and `session_id:`).
extract_envelope_keys() {
    local file="$1"
    awk '/harness: "/{found=1} found' "$file" |
        sed -n '/^    .\{0,3\}{$/,/^    }/p' |
        grep -oE '^\s+[a-z_]+:' |
        sed 's/[: ]//g' |
        sort -u
}

# Both files emit MULTIPLE `result: {`/`usage: {` blocks — early-exit error
# envelopes (watchdog timeout, non-zero exit, no agent_end event) have a
# smaller `usage` shape than the FINAL success/failure envelope, and
# `result:`/`usage:` appear BEFORE `harness: "` within each envelope's own
# `jq -n` object literal, so the `harness: "`-anchored filter
# extract_envelope_keys() uses cannot scope these the same way. The FINAL
# envelope is always the LAST `result: {`/`usage: {` block in the file
# (early-exit envelopes are emitted first, each followed by its own `exit`);
# select the LAST matching line number and extract from there so these
# helpers never pick up an early-exit block's narrower shape and report a
# phantom mismatch.
extract_result_keys() {
    local file="$1"
    local start_line
    start_line=$(grep -n 'result: {' "$file" | tail -1 | cut -d: -f1)
    tail -n "+${start_line}" "$file" |
        awk '/result: \{/,/^\s+\},?$/' |
        grep -oE '^\s+[a-z_]+:' |
        sed 's/[: ]//g' |
        sort -u
}

extract_usage_keys() {
    local file="$1"
    local start_line
    start_line=$(grep -n 'usage: {' "$file" | tail -1 | cut -d: -f1)
    tail -n "+${start_line}" "$file" |
        awk '/usage: \{/,/^\s+\},?$/' |
        grep -oE '^\s+[a-z_]+:' |
        sed 's/[: ]//g' |
        sort -u
}

test_envelope_top_keys() {
    local claude_keys pi_keys diff
    claude_keys=$(extract_envelope_keys "$CLAUDE_LEG")
    pi_keys=$(extract_envelope_keys "$PI_LEG")
    diff=$(diff <(printf '%s\n' "$claude_keys") <(printf '%s\n' "$pi_keys") || true)
    if [ -z "$diff" ]; then
        assert_true "envelope top-level key set matches (claude vs pi)" 0
    else
        echo "  key-set diff:"
        printf '%s\n' "$diff" | sed 's/^/  /'
        assert_true "envelope top-level key set matches (claude vs pi)" 1
    fi
}

test_result_keys() {
    local claude_keys pi_keys diff
    claude_keys=$(extract_result_keys "$CLAUDE_LEG")
    pi_keys=$(extract_result_keys "$PI_LEG")
    diff=$(diff <(printf '%s\n' "$claude_keys") <(printf '%s\n' "$pi_keys") || true)
    if [ -z "$diff" ]; then
        assert_true "envelope 'result' sub-object key set matches" 0
    else
        echo "  key-set diff:"
        printf '%s\n' "$diff" | sed 's/^/  /'
        assert_true "envelope 'result' sub-object key set matches" 1
    fi
}

test_usage_keys() {
    local claude_keys pi_keys diff
    claude_keys=$(extract_usage_keys "$CLAUDE_LEG")
    pi_keys=$(extract_usage_keys "$PI_LEG")
    diff=$(diff <(printf '%s\n' "$claude_keys") <(printf '%s\n' "$pi_keys") || true)
    if [ -z "$diff" ]; then
        assert_true "envelope 'usage' sub-object key set matches" 0
    else
        echo "  key-set diff:"
        printf '%s\n' "$diff" | sed 's/^/  /'
        assert_true "envelope 'usage' sub-object key set matches" 1
    fi
}

test_claude_vars_in_pi
test_pi_vars_in_claude
test_envelope_top_keys
test_result_keys
test_usage_keys

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
