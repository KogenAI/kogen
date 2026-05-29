#!/bin/bash
# orchestrator-no-source-edit_test.sh — unit tests for orchestrator-no-source-edit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/orchestrator-no-source-edit.sh"

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

# Test 1: orchestrator Edit on lib/combobulate/foo.ex — BLOCK
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on lib/ blocks" "2" "$FIXTURE_BLOCK"

# Test 2: subagent (non-empty agent_id) Edit on lib/ — ALLOW
FIXTURE_SUBAGENT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"abc123","agent_type":"developer-phoenix-backend"}'
run_test "subagent Edit on lib/ allows" "0" "$FIXTURE_SUBAGENT"

# Test 3: orchestrator Edit on codegen/logging/x.md — ALLOW
FIXTURE_LOG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/x.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on codegen/logging/ allows" "0" "$FIXTURE_LOG"

# Test 4: orchestrator Edit on CLAUDE.md — BLOCK (top-level .md no longer allowed)
FIXTURE_CLAUDE='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on CLAUDE.md blocks" "2" "$FIXTURE_CLAUDE"

# Test 5: orchestrator Edit on tmp/foo.txt relative — BLOCK (relative tmp/ no longer allowed)
FIXTURE_TMP='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"tmp/foo.txt","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on relative tmp/ blocks" "2" "$FIXTURE_TMP"

# Test 6: orchestrator Edit on absolute path inside codegen/logging/ — ALLOW
# Simulates Claude Code passing file_path as an absolute path (e.g. /Users/.../combobulate/codegen/logging/foo.md)
CWD_ABS="$(mktemp -d)"
ABS_LOG_PATH="${CWD_ABS}/codegen/logging/session.md"
FIXTURE_ABS_LOG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$ABS_LOG_PATH"'","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$CWD_ABS"'"}'
run_test "orchestrator Edit on absolute codegen/logging/ path allows" "0" "$FIXTURE_ABS_LOG"
rm -rf "$CWD_ABS"

# Test 7: orchestrator Edit on absolute path inside lib/ — BLOCK
CWD_ABS2="$(mktemp -d)"
ABS_LIB_PATH="${CWD_ABS2}/lib/app/foo.ex"
FIXTURE_ABS_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$ABS_LIB_PATH"'","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$CWD_ABS2"'"}'
run_test "orchestrator Edit on absolute lib/ path blocks" "2" "$FIXTURE_ABS_BLOCK"
rm -rf "$CWD_ABS2"

# Test 8: combobulate orchestrator + sibling OCG codegen path — BLOCK (must delegate)
COMBO_CWD="/Users/almirsarajcic/Projects/AppBuilder/combobulate"
FIXTURE_SIBLING_CODEGEN='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Areas/Optimum/codegen/harnesses/claude/hooks/foo.sh","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$COMBO_CWD"'"}'
run_test "combobulate orchestrator on sibling codegen blocks (must delegate)" "2" "$FIXTURE_SIBLING_CODEGEN"

# Test 9: combobulate orchestrator + sibling context path — BLOCK (must delegate)
FIXTURE_SIBLING_CONTEXT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Areas/Optimum/context/rules/foo.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$COMBO_CWD"'"}'
run_test "combobulate orchestrator on sibling context blocks (must delegate)" "2" "$FIXTURE_SIBLING_CONTEXT"

# Test 10: combobulate orchestrator + arbitrary outside path — BLOCK
FIXTURE_ARBITRARY='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Other/foo.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$COMBO_CWD"'"}'
run_test "combobulate orchestrator on arbitrary outside path blocks" "2" "$FIXTURE_ARBITRARY"

# Test 11: DIFFERENT cwd (skeptic_bot) + sibling codegen path — BLOCK (safety guard)
OTHER_CWD="/Users/almirsarajcic/Areas/Optimum/skeptic_bot"
FIXTURE_OTHER_SIBLING='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Areas/Optimum/codegen/harnesses/claude/hooks/foo.sh","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$OTHER_CWD"'"}'
run_test "non-combobulate orchestrator on sibling codegen blocks" "2" "$FIXTURE_OTHER_SIBLING"

# Test 12: fake nested path /fake/codegen/logging/test.md — BLOCK (path injection guard)
FIXTURE_FAKE_NESTED='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/fake/codegen/logging/test.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator Write on /fake/codegen/logging/ blocks" "2" "$FIXTURE_FAKE_NESTED"

run_test_role() {
    local desc="$1"
    local expected="$2"
    local role="$3"
    local input="$4"

    local stdout
    stdout=$(printf '%s' "$input" | CLAUDE_ROLE="$role" bash "$GUARD" 2>/dev/null || true)

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 13: CLAUDE_ROLE=debug + Edit on lib/ — BLOCK
FIXTURE_DEBUG_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Edit on lib/ blocks" "2" "debug" "$FIXTURE_DEBUG_LIB"

# Test 14: CLAUDE_ROLE=debug + Edit on codegen/logging/ — BLOCK (debug only writes to pitches/)
FIXTURE_DEBUG_LOG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/session.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Edit on codegen/logging/ blocks" "2" "debug" "$FIXTURE_DEBUG_LOG"

# Test 15: CLAUDE_ROLE=debug + Write to codegen/pitches/draft/ — ALLOW
FIXTURE_DEBUG_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Write to pitches/draft/ allows" "0" "debug" "$FIXTURE_DEBUG_DRAFT"

# Test 16: CLAUDE_ROLE=debug + Edit codegen/pitches/ready/ — ALLOW
FIXTURE_DEBUG_READY='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/pitches/ready/foo.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Edit on pitches/ready/ allows" "0" "debug" "$FIXTURE_DEBUG_READY"

# Test 17: CLAUDE_ROLE=shape + Write to codegen/pitches/draft/ — ALLOW
FIXTURE_SHAPE_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_role "shape mode Write to pitches/draft/ allows" "0" "shape" "$FIXTURE_SHAPE_DRAFT"

# Test 18: CLAUDE_ROLE=shape + Edit lib/ — BLOCK
FIXTURE_SHAPE_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "shape mode Edit on lib/ blocks" "2" "shape" "$FIXTURE_SHAPE_LIB"

# Test 18b: CLAUDE_ROLE=refactor + Write to codegen/pitches/draft/ — ALLOW
FIXTURE_REFACTOR_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_role "refactor mode Write to pitches/draft/ allows" "0" "refactor" "$FIXTURE_REFACTOR_DRAFT"

# Test 18c: CLAUDE_ROLE=refactor + Edit lib/ — BLOCK
FIXTURE_REFACTOR_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "refactor mode Edit on lib/ blocks" "2" "refactor" "$FIXTURE_REFACTOR_LIB"

# Test 18d: CLAUDE_ROLE=ops + Write arbitrary on-box path — ALLOW (full write surface)
FIXTURE_OPS_ONBOX='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/srv/myapp/config.yaml","content":"x"},"agent_id":"","agent_type":""}'
run_test_role "ops mode Write to arbitrary on-box path allows" "0" "ops" "$FIXTURE_OPS_ONBOX"

# Test 18e: CLAUDE_ROLE=ops + Edit lib/ — ALLOW (ops has full write surface)
FIXTURE_OPS_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "ops mode Edit on lib/ allows" "0" "ops" "$FIXTURE_OPS_LIB"

# Test 19: CLAUDE_ROLE=debug + subagent Edit on lib/ — BLOCK (subagent bypass disabled under debug/shape/refactor)
FIXTURE_DEBUG_SUB_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"abc123","agent_type":"general-purpose"}'
run_test_role "debug mode subagent Edit on lib/ blocks" "2" "debug" "$FIXTURE_DEBUG_SUB_LIB"

# Test 20: CLAUDE_ROLE=debug + subagent Write to pitches/draft/ — ALLOW
FIXTURE_DEBUG_SUB_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"abc123","agent_type":"general-purpose"}'
run_test_role "debug mode subagent Write to pitches/draft/ allows" "0" "debug" "$FIXTURE_DEBUG_SUB_DRAFT"

# Test 21: orchestrator (no role) Write to pitches/draft/ — ALLOW (codegen/pitches/ open to every session)
FIXTURE_PLAIN_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to pitches/draft/ allows" "0" "$FIXTURE_PLAIN_DRAFT"

# Test 22: no role + absolute /tmp/foo.txt — ALLOW
FIXTURE_ABS_TMP='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/scratch.txt","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to absolute /tmp/ allows" "0" "$FIXTURE_ABS_TMP"

# Test 23: orchestrator (no role) Write to codegen/pitches/ready/ — ALLOW
FIXTURE_PLAIN_READY='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/ready/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to pitches/ready/ allows" "0" "$FIXTURE_PLAIN_READY"

# Test 24: orchestrator (no role) Write to codegen/pitches/shipped/ — ALLOW
FIXTURE_PLAIN_SHIPPED='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/shipped/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to pitches/shipped/ allows" "0" "$FIXTURE_PLAIN_SHIPPED"

# Test 25: orchestrator (no role) Write to absolute codegen/pitches/ path under cwd — ALLOW
CWD_PITCHES="$(mktemp -d)"
ABS_PITCHES_PATH="${CWD_PITCHES}/codegen/pitches/draft/foo.md"
FIXTURE_ABS_PITCHES='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$ABS_PITCHES_PATH"'","content":"x"},"agent_id":"","agent_type":"","cwd":"'"$CWD_PITCHES"'"}'
run_test "orchestrator (no role) Write to absolute codegen/pitches/ path allows" "0" "$FIXTURE_ABS_PITCHES"
rm -rf "$CWD_PITCHES"

# Test 26: orchestrator (no role) Write to /fake/codegen/pitches/ — BLOCK (path-injection guard)
FIXTURE_FAKE_PITCHES='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/fake/codegen/pitches/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator Write on /fake/codegen/pitches/ blocks" "2" "$FIXTURE_FAKE_PITCHES"

run_test_parity() {
    local desc="$1"
    local expected="$2"
    local env_var="$3"
    local role_val="$4"
    local input="$5"

    local stdout
    stdout=$(printf '%s' "$input" | env "$env_var=$role_val" bash "$GUARD" 2>/dev/null || true)

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# PI_ROLE parity tests

# Test 27: PI_ROLE=debug + Edit on lib/ — BLOCK
FIXTURE_PI_DEBUG_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_parity "PI_ROLE=debug Edit on lib/ blocks" "2" "PI_ROLE" "debug" "$FIXTURE_PI_DEBUG_LIB"

# Test 28: PI_ROLE=debug + Write to codegen/pitches/draft/ — ALLOW
FIXTURE_PI_DEBUG_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_parity "PI_ROLE=debug Write to pitches/draft/ allows" "0" "PI_ROLE" "debug" "$FIXTURE_PI_DEBUG_DRAFT"

# Test 29: PI_ROLE=shape + Edit lib/ — BLOCK
FIXTURE_PI_SHAPE_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_parity "PI_ROLE=shape Edit on lib/ blocks" "2" "PI_ROLE" "shape" "$FIXTURE_PI_SHAPE_LIB"

# Test 30: PI_ROLE=shape + Write to codegen/pitches/draft/ — ALLOW
FIXTURE_PI_SHAPE_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_parity "PI_ROLE=shape Write to pitches/draft/ allows" "0" "PI_ROLE" "shape" "$FIXTURE_PI_SHAPE_DRAFT"

# Test 30b: PI_ROLE=refactor + Write to codegen/pitches/draft/ — ALLOW
FIXTURE_PI_REFACTOR_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_parity "PI_ROLE=refactor Write to pitches/draft/ allows" "0" "PI_ROLE" "refactor" "$FIXTURE_PI_REFACTOR_DRAFT"

# Precedence tests

# Test 35: CLAUDE_ROLE=debug + PI_ROLE=build → CLAUDE_ROLE wins → debug branch → blocks lib/
FIXTURE_PREC_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
stdout_prec=$(printf '%s' "$FIXTURE_PREC_LIB" | CLAUDE_ROLE=debug PI_ROLE=build bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_prec" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: precedence — CLAUDE_ROLE=debug wins over PI_ROLE=build → blocks lib/\n'
    pass=$((pass + 1))
else
    printf 'FAIL: precedence — CLAUDE_ROLE=debug should win and block lib/ — got allow\n  stdout: %s\n' "$stdout_prec"
    fail=$((fail + 1))
fi

# Test 36: only PI_ROLE=debug set (CLAUDE_ROLE unset) → behaves as debug → blocks lib/
stdout_pi_only=$(printf '%s' "$FIXTURE_PREC_LIB" | PI_ROLE=debug bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_pi_only" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: only PI_ROLE=debug set — behaves as debug, blocks lib/\n'
    pass=$((pass + 1))
else
    printf 'FAIL: only PI_ROLE=debug set — should behave as debug and block lib/ — got allow\n  stdout: %s\n' "$stdout_pi_only"
    fail=$((fail + 1))
fi

# Test 38: all role vars unset → orchestrator default → blocks lib/ (no subagent bypass)
stdout_all_unset=$(printf '%s' "$FIXTURE_PREC_LIB" | bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_all_unset" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'PASS: all role vars unset — orchestrator default, blocks lib/\n'
    pass=$((pass + 1))
else
    printf 'FAIL: all role vars unset — should block lib/ for plain orchestrator — got allow\n  stdout: %s\n' "$stdout_all_unset"
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
