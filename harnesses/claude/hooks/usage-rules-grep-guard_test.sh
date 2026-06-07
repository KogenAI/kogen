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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: developer-phoenix-backend grepping codegen/usage_rules/ — BLOCK
FIXTURE_DEV_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend grep usage_rules blocks" "2" "$FIXTURE_DEV_BLOCK"

# Test 2: planner grepping codegen/usage_rules/ — ALLOW
FIXTURE_PLANNER_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/usage_rules/oban.md"},"agent_type":"planner","agent_id":"abc"}'
run_test "planner grep usage_rules allows" "0" "$FIXTURE_PLANNER_ALLOW"

# Test 3: developer-phoenix-backend grepping codegen/recipes/ — ALLOW
FIXTURE_RECIPES_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo codegen/recipes/INDEX.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend grep recipes allows" "0" "$FIXTURE_RECIPES_ALLOW"

# Test 4: developer-phoenix-backend using Grep tool on usage_rules path — BLOCK
FIXTURE_GREP_TOOL_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"foo","path":"codegen/usage_rules/oban.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend Grep tool on usage_rules blocks" "2" "$FIXTURE_GREP_TOOL_BLOCK"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
