#!/bin/bash
# pre-commit-guard_test.sh — unit tests for pre-commit-guard.sh
#
# Tests:
#   1. git commit is BLOCKED for phoenix-developer (exit 2)
#   2. git status PASSES for phoenix-developer (exit 0)
#   3. git commit PASSES for committer (exit 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/pre-commit-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s
' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: git commit is BLOCKED for phoenix-developer
FIXTURE_COMMIT_BLOCKED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '\''foo'\''"},"agent_type":"phoenix-developer","agent_id":"abc123"}'
run_test "git commit blocked for phoenix-developer" "2" "$FIXTURE_COMMIT_BLOCKED"

# Test 2: git status PASSES for phoenix-developer
FIXTURE_STATUS_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"phoenix-developer","agent_id":"abc123"}'
run_test "git status passes for phoenix-developer" "0" "$FIXTURE_STATUS_ALLOWED"

# Test 3: git commit PASSES for committer
FIXTURE_COMMIT_ALLOWED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m '\''foo'\''"},"agent_type":"committer","agent_id":"abc123"}'
run_test "git commit passes for committer" "0" "$FIXTURE_COMMIT_ALLOWED"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
