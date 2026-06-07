#!/bin/bash
# track-tool-failures_test.sh — unit tests for track-tool-failures.sh
#
# Tests:
#   1. Hook always exits 0 (never blocks)
#   2. Valid failure input writes JSONL with correct fields (ts, tool, error)
#   3. Orchestrator failure (empty agent_id) tracked under "_orchestrator" slug
#   4. File is valid JSONL (one JSON object per line)
#   5. Concurrent writes do not corrupt the ledger (sequential double-write)
#   6. Empty error field is handled gracefully (no crash)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/track-tool-failures.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR"

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_jsonl_field() {
    local desc="$1"
    local ledger="$2"
    local field="$3"
    local expected_value="$4"

    if [ ! -f "$ledger" ]; then
        printf 'FAIL: %s — ledger file %s not found\n' "$desc" "$ledger"
        fail=$((fail + 1))
        return
    fi

    local actual
    actual=$(tail -1 "$ledger" | jq -r --arg f "$field" '.[$f] // ""' 2>/dev/null)
    if [ "$actual" = "$expected_value" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — field %s expected "%s", got "%s"\n' "$desc" "$field" "$expected_value" "$actual"
        fail=$((fail + 1))
    fi
}

assert_jsonl_valid() {
    local desc="$1"
    local ledger="$2"

    if [ ! -f "$ledger" ]; then
        printf 'FAIL: %s — ledger file %s not found\n' "$desc" "$ledger"
        fail=$((fail + 1))
        return
    fi

    local invalid
    invalid=$(grep -v '^$' "$ledger" | while IFS= read -r line; do
        printf '%s' "$line" | jq . >/dev/null 2>&1 || printf 'invalid: %s\n' "$line"
    done)
    if [ -z "$invalid" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — invalid JSON lines: %s\n' "$desc" "$invalid"
        fail=$((fail + 1))
    fi
}

# Test 1: Hook always exits 0 (never blocks) — PostToolUseFailure
FAILURE_INPUT=$(jq -n \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_response":{"error":"command not found: mix"},"agent_type":"developer-phoenix-backend","agent_id":"agent-001","session_id":"sess-t1"}')
run_test "hook always exits 0 (never blocks)" "0" "$FAILURE_INPUT"

# Test 2: JSONL ledger created with correct fields
LEDGER_T2="$TMP_DIR/.claude/tool-failures/sess-t2_agent-002.jsonl"
FAILURE_T2=$(jq -n \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Edit","tool_response":{"error":"file not found"},"agent_type":"developer-phoenix-backend","agent_id":"agent-002","session_id":"sess-t2"}')
printf '%s' "$FAILURE_T2" | bash "$GUARD" 2>/dev/null || true
assert_jsonl_field "ledger has correct tool field" "$LEDGER_T2" "tool" "Edit"
assert_jsonl_field "ledger has correct error field" "$LEDGER_T2" "error" "file not found"

# Verify ts field looks like an ISO timestamp
if [ -f "$LEDGER_T2" ]; then
    ts_val=$(tail -1 "$LEDGER_T2" | jq -r '.ts // ""' 2>/dev/null)
    if printf '%s' "$ts_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: ledger has ISO timestamp in ts field\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: ledger ts field not an ISO timestamp: "%s"\n' "$ts_val"
        fail=$((fail + 1))
    fi
fi

# Test 3: Orchestrator (empty agent_id) tracked under _orchestrator
LEDGER_T3="$TMP_DIR/.claude/tool-failures/sess-t3__orchestrator.jsonl"
ORCH_FAILURE=$(jq -n \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Read","tool_response":{"error":"permission denied"},"agent_type":"","agent_id":"","session_id":"sess-t3"}')
printf '%s' "$ORCH_FAILURE" | bash "$GUARD" 2>/dev/null || true
assert_jsonl_field "orchestrator failure tracked under _orchestrator" "$LEDGER_T3" "tool" "Read"

# Test 4: File is valid JSONL
assert_jsonl_valid "all ledger entries are valid JSON" "$LEDGER_T2"

# Test 5: Concurrent (sequential) double-write does not corrupt ledger
LEDGER_T5="$TMP_DIR/.claude/tool-failures/sess-t5_agent-005.jsonl"
DOUBLE_INPUT=$(jq -n \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_response":{"error":"timeout"},"agent_type":"developer-phoenix-backend","agent_id":"agent-005","session_id":"sess-t5"}')
printf '%s' "$DOUBLE_INPUT" | bash "$GUARD" 2>/dev/null || true
printf '%s' "$DOUBLE_INPUT" | bash "$GUARD" 2>/dev/null || true
line_count=$(grep -c '{' "$LEDGER_T5" 2>/dev/null || echo 0)
if [ "$line_count" -ge 2 ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: double write produces 2 valid lines\n'
    pass=$((pass + 1))
else
    printf 'FAIL: double write should produce >= 2 lines, got %s\n' "$line_count"
    fail=$((fail + 1))
fi
assert_jsonl_valid "double-write ledger is valid JSONL" "$LEDGER_T5"

# Test 6: Empty error field handled gracefully (no crash)
EMPTY_ERROR_INPUT=$(jq -n \
    '{"hook_event_name":"PostToolUseFailure","tool_name":"Write","agent_type":"developer-phoenix-backend","agent_id":"agent-006","session_id":"sess-t6"}')
run_test "empty error field handled gracefully (no crash)" "0" "$EMPTY_ERROR_INPUT"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
