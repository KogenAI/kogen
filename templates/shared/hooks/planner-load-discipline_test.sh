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

# Test 1: planner Read on tdd.md — BLOCK
FIXTURE_TDD='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/subagents/tdd.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read tdd.md blocks" "2" "$FIXTURE_TDD"

# Test 2: planner Read on phoenix.md — ALLOW (not in forbidden list)
FIXTURE_PHOENIX='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/subagents/phoenix.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read phoenix.md allows" "0" "$FIXTURE_PHOENIX"

# Test 3: planner Read on subagents/tdd.md (different path, same basename) — BLOCK
FIXTURE_TDD2='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/subagents/tdd.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read subagents/tdd.md blocks (basename match)" "2" "$FIXTURE_TDD2"

# Test 4: phoenix-developer Read on tdd.md — ALLOW (not planner)
FIXTURE_DEV='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/subagents/tdd.md"},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "phoenix-developer Read tdd.md allows (not planner)" "0" "$FIXTURE_DEV"

# Test 5: planner Read on elixir-code-generation.md — BLOCK
FIXTURE_ECG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/subagents/elixir-code-generation.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner Read elixir-code-generation.md blocks" "2" "$FIXTURE_ECG"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
