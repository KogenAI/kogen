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
trap "rm -f /tmp/ve-gate-history-${TEST_AGENT_ID} /tmp/ve-gate-history-${TEST_AGENT_ID2} /tmp/ve-gate-history-${TEST_AGENT_ID3:-x} /tmp/ve-gate-history-${TEST_AGENT_ID4:-x} /tmp/ve-gate-history-${TEST_AGENT_ID5:-x}" EXIT
FIXTURE_MIX='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test path/to/test.exs"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID2"'"}'
run_test "first mix test allows" "0" "$FIXTURE_MIX"

# Test 4: After first `make ci`, a different `mix test <file>` — ALLOW
# (TEST_AGENT_ID already has `make ci` in its history from Test 1)
FIXTURE_NARROW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo_test.exs"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID"'"}'
run_test "narrow mix test after make ci allows" "0" "$FIXTURE_NARROW"

# Test 5: After first `mix test <file>`, a `mix test <file>:42` (line-narrowed) — ALLOW
TEST_AGENT_ID3="test-ve-agent3-$$"
FIXTURE_FILE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo_test.exs"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID3"'"}'
run_test "first mix test <file> allows" "0" "$FIXTURE_FILE"
FIXTURE_FILE_LINE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo_test.exs:42"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID3"'"}'
run_test "line-narrowed mix test allows" "0" "$FIXTURE_FILE_LINE"

# Test 6: Same `mix test <file>` repeated — BLOCK
FIXTURE_FILE_REPEAT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo_test.exs"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID3"'"}'
run_test "exact-same mix test repeats blocks" "2" "$FIXTURE_FILE_REPEAT"

# Test 7: Whitespace-normalised match — BLOCK (extra spaces should not bypass)
TEST_AGENT_ID4="test-ve-agent4-$$"
FIXTURE_NORM_FIRST='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID4"'"}'
run_test "first make ci (norm test) allows" "0" "$FIXTURE_NORM_FIRST"
FIXTURE_NORM_SECOND='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"  make   ci  "},"agent_type":"verification-engineer","agent_id":"'"$TEST_AGENT_ID4"'"}'
run_test "padded make ci normalises and blocks" "2" "$FIXTURE_NORM_SECOND"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
