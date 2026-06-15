#!/bin/bash
# llm-suite-guard_test.sh — unit tests for llm-suite-guard.sh
#
# Tests:
#   1: make llm → deny for developer-*
#   2: make llm-phoenix → deny for developer-*
#   3: make llm-single FILE=... → allow for developer-*
#   4: make llm-phoenix-seed → allow for developer-*
#   5: make llm → allow for non-developer-* (committer)
#   6: make llm-all → allow for developer-* (suffixed, not bare)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/llm-suite-guard.sh"

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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: make llm → deny for developer-*
run_test "make llm blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 2: make llm-phoenix → deny for developer-*
run_test "make llm-phoenix blocked for developer-phoenix-backend" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-phoenix"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 3: make llm-single FILE=... → allow for developer-*
run_test "make llm-single allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-single FILE=test/my_app/llm_integration/foo_test.exs"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 4: make llm-phoenix-seed → allow for developer-*
run_test "make llm-phoenix-seed allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-phoenix-seed"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 5: make llm → allow for non-developer-* (committer)
run_test "make llm allowed for committer (non-developer-*)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm"},"agent_type":"committer","agent_id":"abc123"}'

# Test 6: make llm-all → allow for developer-* (suffixed target, not bare llm)
run_test "make llm-all allowed for developer-phoenix-backend" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-all"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
