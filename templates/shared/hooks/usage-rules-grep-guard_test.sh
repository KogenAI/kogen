#!/bin/bash
# usage-rules-grep-guard_test.sh — unit tests for usage-rules-grep-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/usage-rules-grep-guard.sh"

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

# Test 1: phoenix-developer grepping codegen/usage_rules/ — BLOCK
FIXTURE_DEV_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "phoenix-developer grep usage_rules blocks" "2" "$FIXTURE_DEV_BLOCK"

# Test 2: planner grepping codegen/usage_rules/ — ALLOW
FIXTURE_PLANNER_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner grep usage_rules allows" "0" "$FIXTURE_PLANNER_ALLOW"

# Test 3: phoenix-developer grepping codegen/recipes/ — ALLOW
FIXTURE_RECIPES_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/recipes/INDEX.md"},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "phoenix-developer grep recipes allows" "0" "$FIXTURE_RECIPES_ALLOW"

# Test 4: phoenix-developer using Grep tool on usage_rules path — BLOCK
FIXTURE_GREP_TOOL_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"foo","path":"codegen/usage_rules/oban.md"},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "phoenix-developer Grep tool on usage_rules blocks" "2" "$FIXTURE_GREP_TOOL_BLOCK"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
