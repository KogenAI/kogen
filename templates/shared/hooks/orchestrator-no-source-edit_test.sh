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

# Test 1: orchestrator Edit on lib/combobulate/foo.ex — BLOCK
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on lib/ blocks" "2" "$FIXTURE_BLOCK"

# Test 2: subagent (non-empty agent_id) Edit on lib/ — ALLOW
FIXTURE_SUBAGENT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/combobulate/foo.ex","old_string":"x","new_string":"y"},"agent_id":"abc123","agent_type":"phoenix-developer"}'
run_test "subagent Edit on lib/ allows" "0" "$FIXTURE_SUBAGENT"

# Test 3: orchestrator Edit on codegen/logging/x.md — ALLOW
FIXTURE_LOG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/x.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on codegen/logging/ allows" "0" "$FIXTURE_LOG"

# Test 4: orchestrator Edit on CLAUDE.md — ALLOW (top-level .md)
FIXTURE_CLAUDE='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on CLAUDE.md allows" "0" "$FIXTURE_CLAUDE"

# Test 5: orchestrator Edit on tmp/foo.txt — ALLOW
FIXTURE_TMP='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"tmp/foo.txt","old_string":"x","new_string":"y"},"agent_id":"","agent_type":""}'
run_test "orchestrator Edit on tmp/ allows" "0" "$FIXTURE_TMP"

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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
