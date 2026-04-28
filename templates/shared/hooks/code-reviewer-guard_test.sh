#!/bin/bash
# code-reviewer-guard_test.sh — unit tests for code-reviewer-guard.sh
#
# Tests:
#   1. Bash tool is BLOCKED for code-reviewer (exit 2)
#   2. Bash tool PASSES for phoenix-developer (exit 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/code-reviewer-guard.sh"

pass=0
fail=0

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

# Test 1: Bash tool is BLOCKED for code-reviewer
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"code-reviewer","agent_id":"abc123"}'
run_test "Bash blocked for code-reviewer" "2" "$FIXTURE_BLOCK"

# Test 2: Bash tool PASSES for phoenix-developer
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"phoenix-developer","agent_id":"abc123"}'
run_test "Bash passes for phoenix-developer" "0" "$FIXTURE_ALLOW"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
