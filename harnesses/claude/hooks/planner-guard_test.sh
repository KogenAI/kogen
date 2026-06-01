#!/bin/bash
# planner-guard_test.sh — unit tests for planner-guard.sh
#
# Tests:
#   1. Write tool is BLOCKED for planner-phoenix (exit 2)
#   2. Write tool PASSES for developer-phoenix-backend (exit 0)
#   (+ Read-tool load-discipline cases migrated from planner-load-discipline_test.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/planner-guard.sh"

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
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: Write tool is BLOCKED for planner-phoenix
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/foo.ex","content":"x"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "Write blocked for planner-phoenix" "2" "$FIXTURE_BLOCK"

# Test 2: Write tool PASSES for developer-phoenix-backend
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/foo.ex","content":"x"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "Write passes for developer-phoenix-backend" "0" "$FIXTURE_ALLOW"

# Test 3: planner-html Bash with `2>&1 | head` should NOT be wrongly blocked as a redirect
FIXTURE_STDERR='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo lib/bar.ex 2>&1 | head"},"agent_type":"planner-html","agent_id":"abc123"}'
run_test "planner-html Bash with 2>&1 pipe allows" "0" "$FIXTURE_STDERR"

# Test 4: planner-vite make ci — BLOCK
FIXTURE_CI_FAST='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make ci"},"agent_type":"planner-vite","agent_id":"abc123"}'
run_test "planner-vite make ci blocks" "2" "$FIXTURE_CI_FAST"

# Test 5: planner-hugo make llm-summary — BLOCK
FIXTURE_LLM_SUMMARY='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-summary"},"agent_type":"planner-hugo","agent_id":"abc123"}'
run_test "planner-hugo make llm-summary blocks" "2" "$FIXTURE_LLM_SUMMARY"

# Test 6: planner-phoenix make llm-kill — BLOCK
FIXTURE_LLM_KILL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-kill"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "planner-phoenix make llm-kill blocks" "2" "$FIXTURE_LLM_KILL"

# Test 7: planner-phoenix make llm-retry — BLOCK
FIXTURE_LLM_RETRY='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-retry"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "planner-phoenix make llm-retry blocks" "2" "$FIXTURE_LLM_RETRY"

# Test 8: mv /tmp/a /etc/passwd — BLOCK (dest outside allowed dirs)
FIXTURE_MV_ESCAPE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mv /tmp/a /etc/passwd"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "planner-phoenix mv to /etc/passwd blocks" "2" "$FIXTURE_MV_ESCAPE"

# Test 9: mv /tmp/a /tmp/b — ALLOW (both in /tmp/)
FIXTURE_MV_TMP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mv /tmp/a /tmp/b"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "planner-phoenix mv within /tmp/ allows" "0" "$FIXTURE_MV_TMP"

# Test 10: Edit on codegen/logging/session.md — ALLOW
FIXTURE_EDIT_LOG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/session.md","old_string":"x","new_string":"## planner Section\ny"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "planner-phoenix Edit on codegen/logging/ allows" "0" "$FIXTURE_EDIT_LOG"

# Test 11: Edit on deep/fake/codegen/logging/forged.md — BLOCK (not a direct child)
FIXTURE_EDIT_FAKE='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"deep/fake/codegen/logging/forged.md","old_string":"x","new_string":"y"},"agent_type":"planner-html","agent_id":"abc123"}'
run_test "planner-html Edit on deep/fake/codegen/logging/ blocks" "2" "$FIXTURE_EDIT_FAKE"

# Test 12: planner-phoenix make llm-phoenix-seed — BLOCK
FIXTURE_SEED='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make llm-phoenix-seed"},"agent_type":"planner-phoenix","agent_id":"abc123"}'
run_test "planner-phoenix make llm-phoenix-seed blocks" "2" "$FIXTURE_SEED"

# Test 13: planner-vite Bash with ../ path traversal — BLOCK
FIXTURE_TRAVERSAL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat ../../../etc/passwd"},"agent_type":"planner-vite","agent_id":"abc123"}'
run_test "planner-vite path traversal ../ blocks" "2" "$FIXTURE_TRAVERSAL"

# Test 14: non-planner Bash with ../ path traversal — ALLOW (guard only applies to planner-*)
FIXTURE_TRAVERSAL_OTHER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat ../../../etc/passwd"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "non-planner path traversal ../ not blocked by planner-guard" "0" "$FIXTURE_TRAVERSAL_OTHER"

# ── Read-tool load-discipline cases (migrated from planner-load-discipline_test.sh) ──

# Test 15: planner-phoenix Read on testing.md — BLOCK
FIXTURE_READ_TEST='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/stacks/phoenix/testing.md"},"agent_type":"planner-phoenix","agent_id":"abc"}'
run_test "planner-phoenix Read stacks/phoenix/testing.md blocks" "2" "$FIXTURE_READ_TEST"

# Test 16: planner-html Read on phoenix/_core.md — ALLOW (not in forbidden list)
FIXTURE_READ_CORE='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/stacks/phoenix/_core.md"},"agent_type":"planner-html","agent_id":"abc"}'
run_test "planner-html Read stacks/phoenix/_core.md allows" "0" "$FIXTURE_READ_CORE"

# Test 17: planner-vite Read on roles/reviewer.md — BLOCK (impl-only)
FIXTURE_READ_REVIEWER='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/roles/reviewer.md"},"agent_type":"planner-vite","agent_id":"abc"}'
run_test "planner-vite Read reviewer.md blocks (impl-only)" "2" "$FIXTURE_READ_REVIEWER"

# Test 18: developer-phoenix-backend Read on testing.md — ALLOW (not planner)
FIXTURE_READ_DEV='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/stacks/phoenix/testing.md"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer-phoenix-backend Read stacks/phoenix/testing.md allows (not planner)" "0" "$FIXTURE_READ_DEV"

# Test 19: planner-hugo Read on roles/developer.md — BLOCK (impl-only)
FIXTURE_READ_DEV2='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/roles/developer.md"},"agent_type":"planner-hugo","agent_id":"abc"}'
run_test "planner-hugo Read developer.md blocks (impl-only)" "2" "$FIXTURE_READ_DEV2"

# Test 20: planner-phoenix Read on a session log — ALLOW (not a forbidden implementer file)
FIXTURE_READ_LOG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/logging/20260517_step1_session.md"},"agent_type":"planner-phoenix","agent_id":"abc"}'
run_test "planner-phoenix Read session log allows" "0" "$FIXTURE_READ_LOG"

# Test 21: planner-phoenix Read on committer.md — BLOCK (impl-only)
FIXTURE_READ_COMMITTER='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"./codegen/rules/roles/committer.md"},"agent_type":"planner-phoenix","agent_id":"abc"}'
run_test "planner-phoenix Read committer.md blocks (impl-only)" "2" "$FIXTURE_READ_COMMITTER"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
