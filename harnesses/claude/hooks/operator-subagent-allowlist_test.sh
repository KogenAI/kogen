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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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

# 6: developer-phoenix-backend denied under shape (shape is read-only)
run_test "shape + developer-phoenix-backend denied" "deny" "shape" "$(mk_agent 'developer-phoenix-backend')"

# 6b: reviewer-phoenix denied under shape (shape is read-only)
run_test "shape + reviewer-phoenix denied" "deny" "shape" "$(mk_agent 'reviewer-phoenix')"

# 6c: committer denied under shape (shape is read-only)
run_test "shape + committer denied" "deny" "shape" "$(mk_agent 'committer')"

# 7: planner-phoenix allowed under shape (planner is investigation, not editing)
run_test "shape + planner-phoenix allowed" "allow" "shape" "$(mk_agent 'planner-phoenix')"

# 8: reviewer-phoenix allowed under debug (project subagents allowed everywhere)
run_test "debug + reviewer-phoenix allowed" "allow" "debug" "$(mk_agent 'reviewer-phoenix')"

# 9: Hook active under unrelated role (orchestrator, no CLAUDE_ROLE set) — Explore denied
ORCHESTRATOR_EXPLORE_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_orch=$(printf '%s' "$ORCHESTRATOR_EXPLORE_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_orch" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: orchestrator (no CLAUDE_ROLE) Explore denied — only allowed under debug/design\n'
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: debug + non-Agent tool ignored by this hook\n'
    pass=$((pass + 1))
fi

# 11: empty subagent_type denied under debug (defensive — should never happen but if it does, fail closed)
run_test "debug + empty subagent_type denied" "deny" "debug" "$(mk_agent '')"

# 12: unset + Plan denied (built-in denied in all modes)
ORCHESTRATOR_PLAN_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Plan","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_plan=$(printf '%s' "$ORCHESTRATOR_PLAN_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_plan" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + Plan denied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: unset CLAUDE_ROLE + Plan should be denied — got allow\n  stdout: %s\n' "$stdout_plan"
    fail=$((fail + 1))
fi

# 13: unset + Explore denied (must mention claude-debug or claude-shape in reason)
ORCHESTRATOR_EXPLORE2_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_explore2=$(printf '%s' "$ORCHESTRATOR_EXPLORE2_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_explore2" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_explore2" | grep -qE 'claude-debug|claude-shape'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + Explore denied with claude-debug/claude-shape mention\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: unset CLAUDE_ROLE + Explore denied but reason does not mention claude-debug or claude-shape\n  stdout: %s\n' "$stdout_explore2"
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + general-purpose denied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: unset CLAUDE_ROLE + general-purpose should be denied — got allow\n  stdout: %s\n' "$stdout_gp"
    fail=$((fail + 1))
fi

# 15: unset + statusline-setup denied (built-in denied in all modes)
ORCHESTRATOR_SLS_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"statusline-setup","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_sls=$(printf '%s' "$ORCHESTRATOR_SLS_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_sls" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + statusline-setup denied\n'
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + planner-phoenix allowed\n'
    pass=$((pass + 1))
fi

# 17: unset + committer allowed (project subagent, no CLAUDE_ROLE restriction)
ORCHESTRATOR_COMMITTER_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"committer","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_committer=$(printf '%s' "$ORCHESTRATOR_COMMITTER_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_committer" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: unset CLAUDE_ROLE + committer should be allowed — got deny\n  stdout: %s\n' "$stdout_committer"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + committer allowed\n'
    pass=$((pass + 1))
fi

# 18: debug + Plan denied (explicit debug variant — test 4 covers design+Plan)
run_test "debug + Plan denied" "deny" "debug" "$(mk_agent 'Plan')"

# 19: shape + general-purpose denied (explicit shape variant — test 3 covers debug+general-purpose)
run_test "shape + general-purpose denied" "deny" "shape" "$(mk_agent 'general-purpose')"

# 19d: ops + Explore allowed (ops needs Agent/Explore for on-box investigation)
run_test "ops + Explore allowed" "allow" "ops" "$(mk_agent 'Explore')"

# 19e: ops + Plan denied (built-in denied always, even under ops)
run_test "ops + Plan denied" "deny" "ops" "$(mk_agent 'Plan')"

# 19f: ops + developer-phoenix-backend allowed (project subagents always allowed)
run_test "ops + developer-phoenix-backend allowed" "allow" "ops" "$(mk_agent 'developer-phoenix-backend')"

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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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

# ── Message-content tests: deny strings name the legal subagent set ──────────

# 22a: build-mode (no CLAUDE_ROLE) + Plan → deny AND stdout names "planner"
INPUT_22A=$(mk_agent 'Plan')
stdout_22a=$(printf '%s' "$INPUT_22A" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_22a" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_22a" | grep -q 'planner'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22a build + Plan denied with "planner" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22a build + Plan denied but reason does not mention "planner"\n  stdout: %s\n' "$stdout_22a"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: 22a build + Plan should be denied — got allow\n  stdout: %s\n' "$stdout_22a"
    fail=$((fail + 1))
fi

# 22b: build-mode (no CLAUDE_ROLE) + empty subagent_type → deny AND stdout names legal set
INPUT_22B=$(mk_agent '')
stdout_22b=$(printf '%s' "$INPUT_22B" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_22b" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_22b" | grep -q 'planner'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22b build + empty subagent_type denied with "planner" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22b build + empty subagent_type denied but reason does not mention "planner"\n  stdout: %s\n' "$stdout_22b"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: 22b build + empty subagent_type should be denied — got allow\n  stdout: %s\n' "$stdout_22b"
    fail=$((fail + 1))
fi

# 22c: build-mode (no CLAUDE_ROLE) + general-purpose → deny AND stdout names legal set
INPUT_22C=$(mk_agent 'general-purpose')
stdout_22c=$(printf '%s' "$INPUT_22C" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_22c" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_22c" | grep -q 'planner'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22c build + general-purpose denied with "planner" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22c build + general-purpose denied but reason does not mention "planner"\n  stdout: %s\n' "$stdout_22c"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: 22c build + general-purpose should be denied — got allow\n  stdout: %s\n' "$stdout_22c"
    fail=$((fail + 1))
fi

# 22d: shape + developer-phoenix-backend → deny AND stdout names shape-available set (planner / Explore)
INPUT_22D=$(mk_agent 'developer-phoenix-backend')
stdout_22d=$(printf '%s' "$INPUT_22D" | CLAUDE_ROLE=shape bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_22d" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_22d" | grep -q 'planner' && printf '%s' "$stdout_22d" | grep -q 'Explore'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22d shape + developer-phoenix-backend denied with "planner" and "Explore" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22d shape + developer-phoenix-backend denied but reason missing "planner" or "Explore"\n  stdout: %s\n' "$stdout_22d"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: 22d shape + developer-phoenix-backend should be denied — got allow\n  stdout: %s\n' "$stdout_22d"
    fail=$((fail + 1))
fi

# 23a: isolation:"worktree" denied — fires before subagent_type allow/deny logic
INPUT_23A='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"developer-phoenix-backend","isolation":"worktree"},"agent_id":"","agent_type":""}'
stdout_23a=$(printf '%s' "$INPUT_23A" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_23a" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: 23a isolation:worktree denied\n'
    pass=$((pass + 1))
else
    printf 'FAIL: 23a isolation:worktree should be denied — got allow\n  stdout: %s\n' "$stdout_23a"
    fail=$((fail + 1))
fi

# 23b: no isolation param — allowed (project subagent, build mode)
run_test "23b no isolation param allowed" "allow" "" \
    '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"developer-phoenix-backend"},"agent_id":"","agent_type":""}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
