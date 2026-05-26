#!/bin/bash
# orchestrator-no-ci_test.sh — unit tests for orchestrator-no-ci.sh
#
# Tests:
#   1:  orchestrator make ci → deny (2)
#   2:  orchestrator make ci-fast → deny (2) — literal observed violation
#   3:  orchestrator make ci-fast 2>&1 | tail -100 → deny (2) — literal observed command
#   4:  orchestrator make gate-status → allow (0) — INCONCLUSIVE recovery
#   5:  orchestrator make gate-logs → allow (0)
#   6:  orchestrator make gate-kill → allow (0)
#   7:  orchestrator make llm-phoenix → deny (2)
#   8:  orchestrator mix test (bare) → deny (2)
#   9:  orchestrator mix test test/foo_test.exs → deny (2) — orchestrator NEVER runs tests
#   10: developer-phoenix-backend make ci-fast → allow (0) — dev-no-ci.sh owns this
#   11: planner-phoenix make ci-fast → allow (0) — planner-guard.sh owns this
#   12: subagent with non-empty agent_id, empty agent_type, make ci-fast → allow (0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/orchestrator-no-ci.sh"

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

# Orchestrator inputs: agent_type="" and agent_id="" (both absent/empty)

# Test 1: make ci → deny
run_test "orchestrator make ci → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 2: make ci-fast → deny (literal observed violation)
run_test "orchestrator make ci-fast → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-fast"},"agent_type":"","agent_id":""}'

# Test 3: make ci-fast 2>&1 | tail -100 → deny (literal observed command incl. pipe)
run_test "orchestrator make ci-fast 2>&1 | tail -100 → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-fast 2>&1 | tail -100"},"agent_type":"","agent_id":""}'

# Test 4: make gate-status → allow (INCONCLUSIVE recovery)
run_test "orchestrator make gate-status → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-status"},"agent_type":"","agent_id":""}'

# Test 5: make gate-logs → allow
run_test "orchestrator make gate-logs → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-logs"},"agent_type":"","agent_id":""}'

# Test 6: make gate-kill → allow
run_test "orchestrator make gate-kill → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-kill"},"agent_type":"","agent_id":""}'

# Test 7: make llm-phoenix → deny
run_test "orchestrator make llm-phoenix → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-phoenix"},"agent_type":"","agent_id":""}'

# Test 8: mix test (bare) → deny
run_test "orchestrator mix test bare → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"","agent_id":""}'

# Test 9: mix test test/foo_test.exs → deny (orchestrator NEVER runs tests)
run_test "orchestrator mix test specific file → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test test/foo_test.exs"},"agent_type":"","agent_id":""}'

# Test 10: developer-phoenix-backend make ci-fast → allow (dev-no-ci.sh owns this)
run_test "developer-phoenix-backend make ci-fast → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-fast"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 11: planner-phoenix make ci-fast → allow (planner-guard.sh owns this)
run_test "planner-phoenix make ci-fast → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-fast"},"agent_type":"planner-phoenix","agent_id":"xyz789"}'

# Test 12: subagent with non-empty agent_id but empty agent_type → allow (not orchestrator)
run_test "subagent non-empty agent_id empty agent_type make ci-fast → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci-fast"},"agent_type":"","agent_id":"subagent999"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
