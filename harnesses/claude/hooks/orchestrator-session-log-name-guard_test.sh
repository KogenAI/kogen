#!/bin/bash
# orchestrator-session-log-name-guard_test.sh — unit tests for orchestrator-session-log-name-guard.sh
#
# Tests:
#   1:  orch Write canonical single-pitch session → allow (0)
#   2:  orch Write canonical step-queue form → allow (0)
#   3:  orch Write progress tracker → allow (0)
#   4:  orch Write session no slug (slug optional) → allow (0)
#   5:  orch Edit canonical session → allow (0)
#   6:  orch Write non-logging lib/foo.ex → allow (0) — pre-check
#   7:  orch Write non-logging even if looks like timestamp → allow (0) — pre-check
#   8:  orch Write codegen/pitches/draft/x.md → allow (0) — pre-check
#   9:  orch Write no timestamp → deny (2)
#   10: orch Write date-only missing HHMMSS → deny (2)
#   11: orch Write missing session/step suffix → deny (2)
#   12: orch Write wrong suffix _log → deny (2)
#   13: orch Write dashes instead of underscores in date → deny (2)
#   14: orch Write wrong extension .txt → deny (2)
#   15: orch Write malformed step no number → deny (2)
#   16: orch Write dot-prefixed path non-canonical → deny (2)
#   17: committer Write non-canonical → allow (0) — not orchestrator
#   18: subagent non-empty AGENT_ID empty AGENT_TYPE → allow (0) — not orchestrator
#   19: orch Bash tool → allow (0) — wrong tool
#   20: CLAUDE_ROLE=ops orch Write non-canonical → allow (0) — ops bypass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/orchestrator-session-log-name-guard.sh"

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

# Test 1: canonical single-pitch session log → allow
run_test "orch Write canonical single-pitch session → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_foo_session.md"},"agent_type":"","agent_id":""}'

# Test 2: canonical step-queue form → allow
run_test "orch Write canonical step-queue → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_step2_foo-bar.md"},"agent_type":"","agent_id":""}'

# Test 3: progress tracker → allow
run_test "orch Write progress tracker → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_progress.md"},"agent_type":"","agent_id":""}'

# Test 4: session with no slug (slug is optional) → allow
run_test "orch Write session no slug → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_session.md"},"agent_type":"","agent_id":""}'

# Test 5: Edit canonical session → allow
run_test "orch Edit canonical session → allow" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/20260608_095358_foo_session.md"},"agent_type":"","agent_id":""}'

# Test 6: non-logging Write lib/foo.ex → allow (pre-check passes through)
run_test "orch Write lib/foo.ex → allow (non-logging pre-check)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"lib/foo.ex"},"agent_type":"","agent_id":""}'

# Test 7: non-logging even if it looks like a timestamp → allow (pre-check)
run_test "orch Write lib/20260608_095358_foo.md → allow (non-logging pre-check)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"lib/20260608_095358_foo.md"},"agent_type":"","agent_id":""}'

# Test 8: pitches draft → allow (non-logging pre-check)
run_test "orch Write codegen/pitches/draft/x.md → allow (non-logging pre-check)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/pitches/draft/x.md"},"agent_type":"","agent_id":""}'

# Test 9: no timestamp at all → deny
run_test "orch Write no timestamp → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/foo.md"},"agent_type":"","agent_id":""}'

# Test 10: date-only missing HHMMSS → deny
run_test "orch Write date-only missing HHMMSS → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_foo.md"},"agent_type":"","agent_id":""}'

# Test 11: missing session/step suffix → deny
run_test "orch Write missing session/step suffix → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_foo.md"},"agent_type":"","agent_id":""}'

# Test 12: wrong suffix _log → deny
run_test "orch Write wrong suffix _log → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_foo_log.md"},"agent_type":"","agent_id":""}'

# Test 13: dashes instead of underscores in timestamp → deny
run_test "orch Write dashes in timestamp → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608-095358_foo_session.md"},"agent_type":"","agent_id":""}'

# Test 14: wrong extension .txt → deny
run_test "orch Write wrong extension .txt → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_foo_session.txt"},"agent_type":"","agent_id":""}'

# Test 15: malformed step — no number after step → deny
run_test "orch Write malformed step no number → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/20260608_095358_step_foo.md"},"agent_type":"","agent_id":""}'

# Test 16: dot-prefixed path should be canonicalised; raw form without slug suffix → deny
# (./codegen/logging/foo.md — repo_relative strips ./ → codegen/logging/foo.md → no timestamp → deny)
run_test "orch Write ./codegen/logging/foo.md → deny" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"./codegen/logging/foo.md"},"agent_type":"","agent_id":""}'

# Test 17: committer Write non-canonical → allow (not orchestrator; AGENT_TYPE=committer)
run_test "committer Write non-canonical → allow (skip: not orchestrator)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/foo.md"},"agent_type":"committer","agent_id":"abc123"}'

# Test 18: subagent with non-empty AGENT_ID, empty AGENT_TYPE → allow (not orchestrator)
run_test "subagent non-empty agent_id empty agent_type → allow (skip)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/foo.md"},"agent_type":"","agent_id":"subagent999"}'

# Test 19: orch Bash tool → allow (wrong tool; guard only fires on Write|Edit)
run_test "orch Bash tool → allow (wrong tool)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"agent_type":"","agent_id":""}'

# Test 20: CLAUDE_ROLE=ops Write non-canonical → allow (ops bypass)
CLAUDE_ROLE=ops run_test "CLAUDE_ROLE=ops Write non-canonical → allow (ops bypass)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"codegen/logging/foo.md"},"agent_type":"","agent_id":""}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
