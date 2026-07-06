#!/bin/bash
# reviewer-guard_test.sh — unit tests for reviewer-guard.sh
#
# Tests:
#   1. Bash tool PASSES for reviewer-phoenix (reviewer-guard no longer gates
#      Bash — reviewer-bash-allowlist.sh governs it; see that hook's tests)
#   2. Bash tool PASSES for reviewer-static  (same as above)
#   3. Bash tool PASSES for developer-phoenix-backend (allow)
#   4. Edit on canonical single-session log ALLOWS (full %H%M%S form)
#   5. Edit on canonical multi-step log ALLOWS (full %H%M%S step form)
#   6. Edit on slug-bearing single log ALLOWS (optional slug)
#   7. Edit on non-canonical path BLOCKS
#   8. Edit on date-only (old schema) multi-step log BLOCKS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/reviewer-guard.sh"

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

FIXTURE_PHOENIX='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Bash passes for reviewer-phoenix (reviewer-guard no longer gates Bash)" "0" "$FIXTURE_PHOENIX"

FIXTURE_STATIC='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm run build"},"agent_type":"reviewer-static","agent_id":"abc123"}'
run_test "Bash passes for reviewer-static (reviewer-guard no longer gates Bash)" "0" "$FIXTURE_STATIC"

FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "Bash passes for developer-phoenix-backend" "0" "$FIXTURE_ALLOW"

FIXTURE_CODEGEN_LOG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf %s \"body\" | codegen-log section --body @-"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Bash codegen-log invocation passes for reviewer-phoenix" "0" "$FIXTURE_CODEGEN_LOG"

# Test 4: Edit on canonical slug-bearing cycle log (full %H%M%S) — ALLOW
FIXTURE_EDIT_SESSION='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/20260602_201515_my-slug_cycle.jsonl","old_string":"x","new_string":"y"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Edit on canonical cycle log allows (full %H%M%S)" "0" "$FIXTURE_EDIT_SESSION"

# Test 5: Edit on the dead pre-JSONL multi-step markdown form — BLOCK (never
# written by codegen-log; JSONL storage has no multi-step alternate).
FIXTURE_EDIT_STEP='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/20260602_201515_step1_my-task.md","old_string":"x","new_string":"y"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Edit on dead multi-step markdown form blocks" "2" "$FIXTURE_EDIT_STEP"

# Test 6: Edit on slug-bearing cycle log — ALLOW (slug schema)
FIXTURE_EDIT_SLUG='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/20260602_201515_my-slug_cycle.jsonl","old_string":"x","new_string":"y"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Edit on slug-bearing cycle log allows" "0" "$FIXTURE_EDIT_SLUG"

# Test 7: Edit on non-canonical path — BLOCK
FIXTURE_EDIT_BAD='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"lib/foo.ex","old_string":"x","new_string":"y"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Edit on non-canonical path blocks" "2" "$FIXTURE_EDIT_BAD"

# Test 8: Edit on old markdown _session.md schema (pre-JSONL) — BLOCK
FIXTURE_EDIT_OLD='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"codegen/logging/20260602_201515_session.md","old_string":"x","new_string":"y"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Edit on old markdown _session.md schema blocks (must use _cycle.jsonl)" "2" "$FIXTURE_EDIT_OLD"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
