#!/bin/bash
# operator-subagent-allowlist_test.sh — unit tests for operator-subagent-allowlist.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/operator-subagent-allowlist.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2" # "deny" or "allow"
    local role="$3"
    local input="$4"

    local stdout
    stdout=$(printf '%s' "$input" | CLAUDE_ROLE="$role" bash "$GUARD" 2>/dev/null || true)

    local outcome="allow"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="deny"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

mk_agent() {
    local stype="$1"
    jq -n --arg s "$stype" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
}

# 1: Explore allowed under debug
run_test "debug + Explore allowed" "allow" "debug" "$(mk_agent 'Explore')"

# 2: Explore allowed under design
run_test "design + Explore allowed" "allow" "design" "$(mk_agent 'Explore')"

# 3: general-purpose denied under debug
run_test "debug + general-purpose denied" "deny" "debug" "$(mk_agent 'general-purpose')"

# 4: Plan denied under design (we don't use Plan tool)
run_test "design + Plan denied" "deny" "design" "$(mk_agent 'Plan')"

# 5: committer denied under debug (closes the git-commit escape hatch)
run_test "debug + committer denied" "deny" "debug" "$(mk_agent 'committer')"

# 6: developer-phoenix-backend denied under design
run_test "design + developer-phoenix-backend denied" "deny" "design" "$(mk_agent 'developer-phoenix-backend')"

# 7: planner-phoenix denied under design
run_test "design + planner-phoenix denied" "deny" "design" "$(mk_agent 'planner-phoenix')"

# 8: reviewer-phoenix denied under debug
run_test "debug + reviewer-phoenix denied" "deny" "debug" "$(mk_agent 'reviewer-phoenix')"

# 9: Hook inactive under unrelated role (orchestrator, no CLAUDE_ROLE set)
ORCHESTRATOR_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"developer-phoenix-backend","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_orch=$(printf '%s' "$ORCHESTRATOR_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_orch" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: orchestrator (no CLAUDE_ROLE) should allow any subagent — got deny\n  stdout: %s\n' "$stdout_orch"
    fail=$((fail + 1))
else
    printf 'PASS: orchestrator (no CLAUDE_ROLE) allows any subagent (hook inactive)\n'
    pass=$((pass + 1))
fi

# 10: Hook inactive for non-Agent tool calls under debug
NON_AGENT_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"agent_id":"","agent_type":""}'
stdout_bash=$(printf '%s' "$NON_AGENT_INPUT" | CLAUDE_ROLE=debug bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_bash" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: debug + Bash should not be touched by Agent-matcher hook — got deny\n  stdout: %s\n' "$stdout_bash"
    fail=$((fail + 1))
else
    printf 'PASS: debug + non-Agent tool ignored by this hook\n'
    pass=$((pass + 1))
fi

# 11: empty subagent_type denied under debug (defensive — should never happen but if it does, fail closed)
run_test "debug + empty subagent_type denied" "deny" "debug" "$(mk_agent '')"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
