#!/bin/bash
# ve-no-stash-guard_test.sh — unit tests for ve-no-stash-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/ve-no-stash-guard.sh"

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

# Test 1: VE Bash git stash — BLOCK
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash"},"agent_type":"verification-engineer","agent_id":"abc"}'
run_test "VE git stash blocks" "2" "$FIXTURE_BLOCK"

# Test 2: VE Bash git status — ALLOW
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"verification-engineer","agent_id":"abc"}'
run_test "VE git status allows" "0" "$FIXTURE_ALLOW"

# Test 3: phoenix-developer Bash git stash — ALLOW (not VE, hook scope)
FIXTURE_DEV='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash"},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "phoenix-developer git stash allows (not VE)" "0" "$FIXTURE_DEV"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
