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

# 5: "committer" (no longer a role — see pitch "committing is deterministic,
# not a model call") allowed under debug (falls through as an unrecognized
# project-subagent string; the fallback path allows everywhere)
run_test "debug + committer allowed" "allow" "debug" "$(mk_agent 'committer')"

# 6: developer-phoenix-backend denied under shape (shape is read-only)
run_test "shape + developer-phoenix-backend denied" "deny" "shape" "$(mk_agent 'developer-phoenix-backend')"

# 6b: reviewer-phoenix denied under shape (shape is read-only)
run_test "shape + reviewer-phoenix denied" "deny" "shape" "$(mk_agent 'reviewer-phoenix')"

# 6c: "committer" (no longer a role) is denied under shape — shape mode is
# now an ALLOWLIST of exactly {Explore, spike-builder}; any unlisted name,
# including a deleted/former role string, denies (fail-closed, not fail-open).
run_test "shape + committer denied (allowlist, not a listed name)" "deny" "shape" "$(mk_agent 'committer')"

# 6d: context-curator denied under shape (allowlist — only Explore/spike-builder)
run_test "shape + context-curator denied (allowlist)" "deny" "shape" "$(mk_agent 'context-curator')"

# 6e: spike-builder allowed under shape (sandboxed feasibility-spike builder)
run_test "shape + spike-builder allowed" "allow" "shape" "$(mk_agent 'spike-builder')"

# 6f: an invented/typo'd subagent name is denied under shape (fail-closed
# allowlist regression test — proves membership churn cannot silently open
# the gate)
run_test "shape + invented name denied (allowlist fail-closed)" "deny" "shape" "$(mk_agent 'totally-made-up-agent')"

# 6g: spike-builder is reachable from debug too, not shape-only — shape's
# allowlist is a NARROWING that applies only inside shape mode (exactly
# {Explore, spike-builder} there); debug carries no such allowlist at all,
# so spike-builder — like any other project subagent — falls through to
# the generic "project subagents allowed everywhere" rule below. The
# sandbox bypass in claude-debug-bash-guard.sh mirrors this: it is active
# under debug and shape alike, not shape-only.
run_test "debug + spike-builder allowed (debug has no allowlist restriction)" "allow" "debug" "$(mk_agent 'spike-builder')"

# 7: context-curator allowed under debug (project subagents allowed everywhere
# except shape's allowlist)
run_test "debug + context-curator allowed" "allow" "debug" "$(mk_agent 'context-curator')"

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

# 16: unset + developer-phoenix-backend allowed (project subagent, no CLAUDE_ROLE restriction)
ORCHESTRATOR_DEVELOPER_INPUT='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"developer-phoenix-backend","description":"x","prompt":"y"},"agent_id":"","agent_type":""}'
stdout_developer=$(printf '%s' "$ORCHESTRATOR_DEVELOPER_INPUT" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_developer" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: unset CLAUDE_ROLE + developer-phoenix-backend should be allowed — got deny\n  stdout: %s\n' "$stdout_developer"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unset CLAUDE_ROLE + developer-phoenix-backend allowed\n'
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

# 19g: experiment + Explore allowed (experiment needs Agent/Explore for investigation)
run_test "experiment + Explore allowed" "allow" "experiment" "$(mk_agent 'Explore')"

# 19h: experiment + Plan denied (built-in denied always, even under experiment)
run_test "experiment + Plan denied" "deny" "experiment" "$(mk_agent 'Plan')"

# 19i: babysit + Explore allowed (babysit needs Agent/Explore for local investigation)
run_test "babysit + Explore allowed" "allow" "babysit" "$(mk_agent 'Explore')"

# 19j: babysit + Plan denied (built-in denied always, even under babysit)
run_test "babysit + Plan denied" "deny" "babysit" "$(mk_agent 'Plan')"

# 19k: babysit + developer-phoenix-backend allowed (project subagents always allowed)
run_test "babysit + developer-phoenix-backend allowed" "allow" "babysit" "$(mk_agent 'developer-phoenix-backend')"

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

# ── Message-content tests: deny strings name the legal subagent set ──────────

# 22a: build-mode (no CLAUDE_ROLE) + Plan → deny AND stdout names "developer-"
INPUT_22A=$(mk_agent 'Plan')
stdout_22a=$(printf '%s' "$INPUT_22A" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_22a" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_22a" | grep -q 'developer-'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22a build + Plan denied with "developer-" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22a build + Plan denied but reason does not mention "developer-"\n  stdout: %s\n' "$stdout_22a"
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
    if printf '%s' "$stdout_22b" | grep -q 'developer-'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22b build + empty subagent_type denied with "developer-" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22b build + empty subagent_type denied but reason does not mention "developer-"\n  stdout: %s\n' "$stdout_22b"
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
    if printf '%s' "$stdout_22c" | grep -q 'developer-'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22c build + general-purpose denied with "developer-" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22c build + general-purpose denied but reason does not mention "developer-"\n  stdout: %s\n' "$stdout_22c"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: 22c build + general-purpose should be denied — got allow\n  stdout: %s\n' "$stdout_22c"
    fail=$((fail + 1))
fi

# 22d: shape + developer-phoenix-backend → deny AND stdout names shape-available set (Explore)
INPUT_22D=$(mk_agent 'developer-phoenix-backend')
stdout_22d=$(printf '%s' "$INPUT_22D" | CLAUDE_ROLE=shape bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_22d" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    if printf '%s' "$stdout_22d" | grep -q 'Explore'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: 22d shape + developer-phoenix-backend denied with "Explore" in reason\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: 22d shape + developer-phoenix-backend denied but reason missing "Explore"\n  stdout: %s\n' "$stdout_22d"
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
