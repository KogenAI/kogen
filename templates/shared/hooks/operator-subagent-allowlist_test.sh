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

# 2: Explore allowed under shape
run_test "shape + Explore allowed" "allow" "shape" "$(mk_agent 'Explore')"

# 3: general-purpose denied under debug
run_test "debug + general-purpose denied" "deny" "debug" "$(mk_agent 'general-purpose')"

# 4: Plan denied under shape (we don't use Plan tool)
run_test "shape + Plan denied" "deny" "shape" "$(mk_agent 'Plan')"

# 5: committer allowed under debug (project subagents are allowed everywhere)
run_test "debug + committer allowed" "allow" "debug" "$(mk_agent 'committer')"

# 6: developer-phoenix-backend allowed under shape (project subagents allowed everywhere)
run_test "shape + developer-phoenix-backend allowed" "allow" "shape" "$(mk_agent 'developer-phoenix-backend')"

# 7: planner-phoenix allowed under shape (project subagents allowed everywhere)
run_test "shape + planner-phoenix allowed" "allow" "shape" "$(mk_agent 'planner-phoenix')"

# 8: reviewer-phoenix allowed under debug (project subagents allowed everywhere)
run_test "debug + reviewer-phoenix allowed" "allow" "debug" "$(mk_agent 'reviewer-phoenix')"

# 9: Hook active under unrelated role (orchestrator, no CLAUDE_ROLE set) — Explore denied
ORCHESTRATOR_EXPLORE_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_orch=$(printf '%s' "$ORCHESTRATOR_EXPLORE_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_orch" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: orchestrator (no CLAUDE_ROLE) Explore denied — only allowed under debug/design\n'
    pass=$((pass + 1))
else
    printf 'FAIL: orchestrator (no CLAUDE_ROLE) should deny Explore — got allow\n  stdout: %s\n' "$stdout_orch"
    fail=$((fail + 1))
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

# 12: unset + Plan denied (built-in denied in all modes)
ORCHESTRATOR_PLAN_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Plan","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_plan=$(printf '%s' "$ORCHESTRATOR_PLAN_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_plan" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: unset CLAUDE_ROLE + Plan denied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: unset CLAUDE_ROLE + Plan should be denied — got allow\n  stdout: %s\n' "$stdout_plan"
    fail=$((fail + 1))
fi

# 13: unset + Explore denied (must mention claude-debug, claude-shape, or claude-refactor in reason)
ORCHESTRATOR_EXPLORE2_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_explore2=$(printf '%s' "$ORCHESTRATOR_EXPLORE2_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_explore2" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_explore2" | grep -qE 'claude-debug|claude-shape|claude-refactor'; then
        printf 'PASS: unset CLAUDE_ROLE + Explore denied with claude-debug/claude-shape/claude-refactor mention\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: unset CLAUDE_ROLE + Explore denied but reason does not mention claude-debug, claude-shape, or claude-refactor\n  stdout: %s\n' "$stdout_explore2"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: unset CLAUDE_ROLE + Explore should be denied — got allow\n  stdout: %s\n' "$stdout_explore2"
    fail=$((fail + 1))
fi

# 14: unset + general-purpose denied (built-in denied in all modes)
ORCHESTRATOR_GP_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_gp=$(printf '%s' "$ORCHESTRATOR_GP_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_gp" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: unset CLAUDE_ROLE + general-purpose denied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: unset CLAUDE_ROLE + general-purpose should be denied — got allow\n  stdout: %s\n' "$stdout_gp"
    fail=$((fail + 1))
fi

# 15: unset + statusline-setup denied (built-in denied in all modes)
ORCHESTRATOR_SLS_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"statusline-setup","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_sls=$(printf '%s' "$ORCHESTRATOR_SLS_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_sls" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: unset CLAUDE_ROLE + statusline-setup denied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: unset CLAUDE_ROLE + statusline-setup should be denied — got allow\n  stdout: %s\n' "$stdout_sls"
    fail=$((fail + 1))
fi

# 16: unset + planner-phoenix allowed (project subagent, no CLAUDE_ROLE restriction)
ORCHESTRATOR_PLANNER_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"planner-phoenix","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_planner=$(printf '%s' "$ORCHESTRATOR_PLANNER_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_planner" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: unset CLAUDE_ROLE + planner-phoenix should be allowed — got deny\n  stdout: %s\n' "$stdout_planner"
    fail=$((fail + 1))
else
    printf 'PASS: unset CLAUDE_ROLE + planner-phoenix allowed\n'
    pass=$((pass + 1))
fi

# 17: unset + committer allowed (project subagent, no CLAUDE_ROLE restriction)
ORCHESTRATOR_COMMITTER_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"committer","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_committer=$(printf '%s' "$ORCHESTRATOR_COMMITTER_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_committer" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: unset CLAUDE_ROLE + committer should be allowed — got deny\n  stdout: %s\n' "$stdout_committer"
    fail=$((fail + 1))
else
    printf 'PASS: unset CLAUDE_ROLE + committer allowed\n'
    pass=$((pass + 1))
fi

# 18: debug + Plan denied (explicit debug variant — test 4 covers design+Plan)
run_test "debug + Plan denied" "deny" "debug" "$(mk_agent 'Plan')"

# 19: shape + general-purpose denied (explicit shape variant — test 3 covers debug+general-purpose)
run_test "shape + general-purpose denied" "deny" "shape" "$(mk_agent 'general-purpose')"

# 19b: refactor + Explore allowed (refactor is investigation mode)
run_test "refactor + Explore allowed" "allow" "refactor" "$(mk_agent 'Explore')"

# 19c: refactor + Plan denied (built-in denied always)
run_test "refactor + Plan denied" "deny" "refactor" "$(mk_agent 'Plan')"

# PI_ROLE parity tests (via env var, no CLAUDE_ROLE set)

run_test_env() {
    local desc="$1"
    local expected="$2"
    local env_var="$3"
    local role_val="$4"
    local input="$5"

    local stdout
    stdout=$(printf '%s' "$input" | env "$env_var=$role_val" bash "$GUARD" 2>/dev/null || true)

    local outcome="allow"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="deny"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# 20: PI_ROLE=debug + Explore allowed
run_test_env "PI_ROLE=debug + Explore allowed" "allow" "PI_ROLE" "debug" "$(mk_agent 'Explore')"

# 21: PI_ROLE=shape + Explore allowed
run_test_env "PI_ROLE=shape + Explore allowed" "allow" "PI_ROLE" "shape" "$(mk_agent 'Explore')"

# 21b: PI_ROLE=refactor + Explore allowed
run_test_env "PI_ROLE=refactor + Explore allowed" "allow" "PI_ROLE" "refactor" "$(mk_agent 'Explore')"

# 22: CODEX_ROLE=debug + Explore allowed
run_test_env "CODEX_ROLE=debug + Explore allowed" "allow" "CODEX_ROLE" "debug" "$(mk_agent 'Explore')"

# 23: CODEX_ROLE=shape + Explore allowed
run_test_env "CODEX_ROLE=shape + Explore allowed" "allow" "CODEX_ROLE" "shape" "$(mk_agent 'Explore')"

# 23b: CODEX_ROLE=refactor + Explore allowed
run_test_env "CODEX_ROLE=refactor + Explore allowed" "allow" "CODEX_ROLE" "refactor" "$(mk_agent 'Explore')"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
