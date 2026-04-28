#!/bin/bash
# commit-only-via-committer_test.sh — unit tests for commit-only-via-committer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/commit-only-via-committer.sh"

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

# Test 1: committer Bash git commit — ALLOW
FIXTURE_COMMITTER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add feature\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer git commit allows" "0" "$FIXTURE_COMMITTER"

# Test 2: orchestrator (empty agent_id) git commit — BLOCK
FIXTURE_ORCHESTRATOR='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add feature\""},"agent_type":"","agent_id":""}'
run_test "orchestrator git commit blocks" "2" "$FIXTURE_ORCHESTRATOR"

# Test 3: phoenix-developer git commit — BLOCK
FIXTURE_DEV='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add feature\""},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "phoenix-developer git commit blocks" "2" "$FIXTURE_DEV"

# Test 4: committer git commit --amend — ALLOW
FIXTURE_AMEND='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit --amend -m \"Fix message\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer git commit --amend allows" "0" "$FIXTURE_AMEND"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
