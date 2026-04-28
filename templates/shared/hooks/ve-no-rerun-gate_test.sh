#!/bin/bash
# ve-no-rerun-gate_test.sh — unit tests for ve-no-rerun-gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/ve-no-rerun-gate.sh"

pass=0
fail=0

TEST_AGENT_ID="test-ve-agent-$$"

# Clean up any history files before and after
cleanup() {
    rm -f "/tmp/ve-gate-history-${TEST_AGENT_ID}"
}
trap cleanup EXIT
cleanup

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    actual_code=$(
        printf '%s' "$input" | bash "$GUARD" 2>/dev/null
        echo $?
    )

    if [ "$actual_code" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected exit %s, got %s\n' "$desc" "$expected" "$actual_code"
        fail=$((fail + 1))
    fi
}

# Test 1: First make ci — ALLOW
FIXTURE_FIRST='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID"'"}'
run_test "first make ci allows" "0" "$FIXTURE_FIRST"

# Test 2: Second make ci from same agent — BLOCK
run_test "second make ci blocks" "2" "$FIXTURE_FIRST"

# Test 3: First mix test (fresh agent) — ALLOW
TEST_AGENT_ID2="test-ve-agent2-$$"
trap "rm -f /tmp/ve-gate-history-${TEST_AGENT_ID} /tmp/ve-gate-history-${TEST_AGENT_ID2}" EXIT
FIXTURE_MIX='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test path/to/test.exs"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID2"'"}'
run_test "first mix test allows" "0" "$FIXTURE_MIX"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
