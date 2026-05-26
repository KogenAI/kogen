#!/bin/bash
# llm-test-guard_test.sh — unit tests for llm-test-guard.sh
#
# Tests:
#   1: bare mix test --only llm_integration → deny
#   2: mix test --only llm_integration with partition != 1 → deny
#   3: mix test --only llm_integration PARTITION=3 PARTITIONS=10 → deny
#   4: mix test --only llm_integration PARTITION=1 PARTITIONS=1 with .exs path → allow
#   5: make llm-single (no mix test invocation) → allow
#   6: make llm (no mix test invocation) → allow
#   7: non-Bash tool → allow
#   8: mix test --only llm_integration PARTITION=1 PARTITIONS=1 without .exs path → deny

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/llm-test-guard.sh"

pass=0
fail=0

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
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: bare mix test --only llm_integration → deny
run_test "bare mix test --only llm_integration blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test --only llm_integration"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 2: mix test --only llm_integration with only PARTITION set → deny
run_test "mix test --only llm_integration with only PARTITION=1 blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_TEST_PARTITION=1 mix test --only llm_integration test/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 3: mix test --only llm_integration PARTITION=3 PARTITIONS=10 → deny (footgun)
run_test "mix test --only llm_integration PARTITION=3 PARTITIONS=10 blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_TEST_PARTITION=3 MIX_TEST_PARTITIONS=10 mix test --only llm_integration test/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 4: PARTITION=1 PARTITIONS=1 with .exs path → allow (make llm-single expansion)
run_test "mix test --only llm_integration PARTITION=1 PARTITIONS=1 with path allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=1 mix test --only llm_integration test/combobulate/llm_integration/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 5: make llm-single → allow (no mix test literal)
run_test "make llm-single allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-single FILE=test/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 6: make llm → allow (no mix test literal)
run_test "make llm allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 7: non-Bash tool → allow
run_test "non-Bash tool allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"mix test --only llm_integration"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 8: PARTITION=1 PARTITIONS=1 but no .exs path → deny (incomplete, not llm-single)
run_test "mix test --only llm_integration PARTITION=1 PARTITIONS=1 without path blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=1 mix test --only llm_integration"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
