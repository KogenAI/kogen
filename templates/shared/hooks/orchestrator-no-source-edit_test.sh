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
FIXTURE_SIBLING_CODEGEN='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Areas/Optimum/codegen/templates/shared/hooks/foo.sh","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$COMBO_CWD"'"}'
run_test "combobulate orchestrator on sibling codegen blocks (must delegate)" "2" "$FIXTURE_SIBLING_CODEGEN"

# Test 9: combobulate orchestrator + sibling context path — BLOCK (must delegate)
FIXTURE_SIBLING_CONTEXT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Areas/Optimum/context/rules/foo.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$COMBO_CWD"'"}'
run_test "combobulate orchestrator on sibling context blocks (must delegate)" "2" "$FIXTURE_SIBLING_CONTEXT"

# Test 10: combobulate orchestrator + arbitrary outside path — BLOCK
FIXTURE_ARBITRARY='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Other/foo.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$COMBO_CWD"'"}'
run_test "combobulate orchestrator on arbitrary outside path blocks" "2" "$FIXTURE_ARBITRARY"

# Test 11: DIFFERENT cwd (skeptic_bot) + sibling codegen path — BLOCK (safety guard)
OTHER_CWD="/Users/almirsarajcic/Areas/Optimum/skeptic_bot"
FIXTURE_OTHER_SIBLING='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/almirsarajcic/Areas/Optimum/codegen/templates/shared/hooks/foo.sh","old_string":"x","new_string":"y"},"agent_id":"","agent_type":"","cwd":"'"$OTHER_CWD"'"}'
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

# Test 14: CLAUDE_ROLE=debug + Edit on codegen/logging/ — BLOCK (debug only writes to designs/)
FIXTURE_DEBUG_LOG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/session.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Edit on codegen/logging/ blocks" "2" "debug" "$FIXTURE_DEBUG_LOG"

# Test 15: CLAUDE_ROLE=debug + Write to codegen/designs/drafts/ — ALLOW
FIXTURE_DEBUG_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/designs/drafts/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Write to drafts/ allows" "0" "debug" "$FIXTURE_DEBUG_DRAFT"

# Test 16: CLAUDE_ROLE=debug + Edit codegen/designs/ready/ — ALLOW (e.g. via /split)
FIXTURE_DEBUG_READY='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/designs/ready/foo.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "debug mode Edit on ready/ allows" "0" "debug" "$FIXTURE_DEBUG_READY"

# Test 17: CLAUDE_ROLE=design + Write to codegen/designs/drafts/ — ALLOW
FIXTURE_DESIGN_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/designs/drafts/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test_role "design mode Write to drafts/ allows" "0" "design" "$FIXTURE_DESIGN_DRAFT"

# Test 18: CLAUDE_ROLE=design + Edit lib/ — BLOCK
FIXTURE_DESIGN_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test_role "design mode Edit on lib/ blocks" "2" "design" "$FIXTURE_DESIGN_LIB"

# Test 19: CLAUDE_ROLE=debug + subagent Edit on lib/ — BLOCK (subagent bypass disabled under debug/design)
FIXTURE_DEBUG_SUB_LIB='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"abc123","agent_type":"general-purpose"}'
run_test_role "debug mode subagent Edit on lib/ blocks" "2" "debug" "$FIXTURE_DEBUG_SUB_LIB"

# Test 20: CLAUDE_ROLE=debug + subagent Write to drafts/ — ALLOW
FIXTURE_DEBUG_SUB_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/designs/drafts/foo.md","content":"x"},"agent_id":"abc123","agent_type":"general-purpose"}'
run_test_role "debug mode subagent Write to drafts/ allows" "0" "debug" "$FIXTURE_DEBUG_SUB_DRAFT"

# Test 21: orchestrator (no role) Write to drafts/ — ALLOW (codegen/designs/ open to every session)
FIXTURE_PLAIN_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/designs/drafts/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to drafts/ allows" "0" "$FIXTURE_PLAIN_DRAFT"

# Test 22: no role + absolute /tmp/foo.txt — ALLOW
FIXTURE_ABS_TMP='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/scratch.txt","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to absolute /tmp/ allows" "0" "$FIXTURE_ABS_TMP"

# Test 23: orchestrator (no role) Write to codegen/designs/ready/ — ALLOW
FIXTURE_PLAIN_READY='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/designs/ready/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to designs/ready/ allows" "0" "$FIXTURE_PLAIN_READY"

# Test 24: orchestrator (no role) Write to codegen/designs/archive/ — ALLOW
FIXTURE_PLAIN_ARCHIVE='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/designs/archive/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator (no role) Write to designs/archive/ allows" "0" "$FIXTURE_PLAIN_ARCHIVE"

# Test 25: orchestrator (no role) Write to absolute codegen/designs/ path under cwd — ALLOW
CWD_DESIGNS="$(mktemp -d)"
ABS_DESIGNS_PATH="${CWD_DESIGNS}/codegen/designs/drafts/foo.md"
FIXTURE_ABS_DESIGNS='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$ABS_DESIGNS_PATH"'","content":"x"},"agent_id":"","agent_type":"","cwd":"'"$CWD_DESIGNS"'"}'
run_test "orchestrator (no role) Write to absolute codegen/designs/ path allows" "0" "$FIXTURE_ABS_DESIGNS"
rm -rf "$CWD_DESIGNS"

# Test 26: orchestrator (no role) Write to /fake/codegen/designs/ — BLOCK (path-injection guard)
FIXTURE_FAKE_DESIGNS='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/fake/codegen/designs/foo.md","content":"x"},"agent_id":"","agent_type":""}'
run_test "orchestrator Write on /fake/codegen/designs/ blocks" "2" "$FIXTURE_FAKE_DESIGNS"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
