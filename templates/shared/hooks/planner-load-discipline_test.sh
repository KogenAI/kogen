#!/bin/bash
# planner-load-discipline_test.sh — unit tests for planner-load-discipline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/planner-load-discipline.sh"

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

# Test 1: planner Read on testing.md — BLOCK
FIXTURE_TB='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/stacks/phoenix/testing.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read stacks/phoenix/testing.md blocks" "2" "$FIXTURE_TB"

# Test 2: planner Read on phoenix/_core.md — ALLOW (not in forbidden list — planner needs framework knowledge)
FIXTURE_PHOENIX='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/stacks/phoenix/_core.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read stacks/phoenix/_core.md allows" "0" "$FIXTURE_PHOENIX"

# Test 3: planner Read on roles/reviewer.md — BLOCK (impl-only)
FIXTURE_AST='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/roles/reviewer.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read reviewer.md blocks (impl-only)" "2" "$FIXTURE_AST"

# Test 4: developer-phoenix-backend Read on testing.md — ALLOW (not planner)
FIXTURE_DEV='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/stacks/phoenix/testing.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend Read stacks/phoenix/testing.md allows (not planner)" "0" "$FIXTURE_DEV"

# Test 5: planner Read on roles/developer.md — BLOCK (impl-only)
FIXTURE_ECG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/roles/developer.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read developer.md blocks (impl-only)" "2" "$FIXTURE_ECG"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
