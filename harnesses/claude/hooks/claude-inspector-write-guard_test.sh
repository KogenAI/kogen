#!/bin/bash
# claude-inspector-write-guard_test.sh — unit tests for claude-inspector-write-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/claude-inspector-write-guard.sh"

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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: Write tool — BLOCK (inspector agent)
FIXTURE_WRITE='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/foo.ex","content":"x"},"agent_type":"inspector","agent_id":"abc"}'
run_test "Write tool blocked for inspector" "2" "$FIXTURE_WRITE"

# Test 2: Edit tool — BLOCK (inspector agent)
FIXTURE_EDIT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.ex","old_string":"x","new_string":"y"},"agent_type":"inspector","agent_id":"abc"}'
run_test "Edit tool blocked for inspector" "2" "$FIXTURE_EDIT"

# Test 3: Read tool — ALLOW (inspector agent)
FIXTURE_READ='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/foo.ex"},"agent_type":"inspector","agent_id":"abc"}'
run_test "Read tool allowed for inspector" "0" "$FIXTURE_READ"

# Test 4: Bash tool — ALLOW (inspector agent; not a write tool)
FIXTURE_BASH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"agent_type":"inspector","agent_id":"abc"}'
run_test "Bash tool allowed for inspector" "0" "$FIXTURE_BASH"

# Test 5: Write tool — ALLOW for developer-phoenix-backend (non-inspector passes through)
FIXTURE_DEV_WRITE='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/foo.ex","content":"x"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "Write tool allowed for developer-phoenix-backend" "0" "$FIXTURE_DEV_WRITE"

# Test 6: Edit tool — ALLOW for orchestrator/empty agent_type (non-inspector passes through)
FIXTURE_ORCH_EDIT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.ex","old_string":"x","new_string":"y"},"agent_type":"","agent_id":""}'
run_test "Edit tool allowed for orchestrator (empty agent_type)" "0" "$FIXTURE_ORCH_EDIT"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
