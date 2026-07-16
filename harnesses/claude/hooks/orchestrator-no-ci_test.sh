#!/bin/bash
# orchestrator-no-ci_test.sh — unit tests for orchestrator-no-ci.sh
#
# Tests:
#   1:  orchestrator make ci → deny (2)
#   2:  orchestrator make ci (duplicate) → deny (2)
#   3:  orchestrator make ci 2>&1 | tail -100 → deny (2)
#   4:  orchestrator make gate-status → allow (0) — INCONCLUSIVE recovery
#   5:  orchestrator make gate-logs → allow (0)
#   6:  orchestrator make gate-kill → allow (0)
#   7:  orchestrator make llm-phoenix → deny (2)
#   8:  orchestrator mix test (bare) → deny (2)
#   9:  orchestrator mix test test/foo_test.exs → deny (2) — orchestrator NEVER runs tests
#   10: developer-phoenix-backend make ci → allow (0) — dev-no-ci.sh owns this
#   11: planner-phoenix make ci → allow (0) — planner-guard.sh owns this
#   12: subagent with non-empty agent_id, empty agent_type, make ci → allow (0)
#   13: CLAUDE_ROLE=ops make ci → allow (0) — ops bypass via resolve_role
#   14: PI_ROLE=ops make ci → allow (0) — ops bypass via resolve_role
#   15: CLAUDE_ROLE=experiment make ci → allow (0) — experiment bypass via resolve_role
#   16: PI_ROLE=experiment make ci → allow (0) — experiment bypass via resolve_role
#   19: CLAUDE_ROLE=babysit make ci → allow (0) — babysit bypass via resolve_role
#   20: PI_ROLE=babysit make ci → allow (0) — babysit bypass via resolve_role

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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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

# Test 2: make ci (duplicate coverage) → deny
run_test "orchestrator make ci → deny (2)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 3: make ci 2>&1 | tail -100 → deny (pipe variant)
run_test "orchestrator make ci 2>&1 | tail -100 → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci 2>&1 | tail -100"},"agent_type":"","agent_id":""}'

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

# Test 10: developer-phoenix-backend make ci → allow (dev-no-ci.sh owns this)
run_test "developer-phoenix-backend make ci → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'

# Test 11: planner-phoenix make ci → allow (planner-guard.sh owns this)
run_test "planner-phoenix make ci → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"planner-phoenix","agent_id":"xyz789"}'

# Test 12: subagent with non-empty agent_id but empty agent_type → allow (not orchestrator)
run_test "subagent non-empty agent_id empty agent_type make ci → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":"subagent999"}'

# Test 13: CLAUDE_ROLE=ops make ci → allow (ops bypass — live box inspection)
CLAUDE_ROLE=ops run_test "CLAUDE_ROLE=ops make ci → allow (ops bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 14: PI_ROLE=ops make ci → allow (ops bypass via PI_ROLE parity)
PI_ROLE=ops run_test "PI_ROLE=ops make ci → allow (ops bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 15: CLAUDE_ROLE=experiment make ci → allow (experiment bypass — standalone dev session)
CLAUDE_ROLE=experiment run_test "CLAUDE_ROLE=experiment make ci → allow (experiment bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 16: PI_ROLE=experiment make ci → allow (experiment bypass via PI_ROLE parity)
PI_ROLE=experiment run_test "PI_ROLE=experiment make ci → allow (experiment bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 17: codegen-log write narrating "make ci" in heredoc body → allow
run_test "codegen-log write narrating gated phrase allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## orchestrator Section\nDelegated to developer; make ci ran green in the gate.\nEOF"},"agent_type":"","agent_id":""}'

# Test 18: real standalone make ci still denied unchanged
run_test "orchestrator real make ci still denied (unchanged)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 19: CLAUDE_ROLE=babysit make ci → allow (babysit bypass — dispatches codegen-build --queue)
CLAUDE_ROLE=babysit run_test "CLAUDE_ROLE=babysit make ci → allow (babysit bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

# Test 20: PI_ROLE=babysit make ci → allow (babysit bypass via PI_ROLE parity)
PI_ROLE=babysit run_test "PI_ROLE=babysit make ci → allow (babysit bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"","agent_id":""}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
