#!/bin/bash
# session-log-section-integrity_test.sh — unit tests for session-log-section-integrity.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/session-log-section-integrity.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

LOG_FILE="$TMP_DIR/codegen/logging/foo.md"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Test 1: developer-phoenix-backend Edit with section header in new_string — ALLOW
NEW_WITH_HEADER=$(printf '## developer-phoenix-backend Section\n\nSome content')
FIXTURE_ALLOW=$(jq -n \
    --arg fp "$LOG_FILE" \
    --arg ns "$NEW_WITH_HEADER" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"","new_string":$ns},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "developer-phoenix-backend Edit with section header allows" "0" "$FIXTURE_ALLOW"

# Test 2: developer-phoenix-backend Edit without section header — BLOCK
NEW_WITHOUT_HEADER="Some content without the required header"
FIXTURE_BLOCK=$(jq -n \
    --arg fp "$LOG_FILE" \
    --arg ns "$NEW_WITHOUT_HEADER" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"","new_string":$ns},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "developer-phoenix-backend Edit without section header blocks" "2" "$FIXTURE_BLOCK"

# Test 3: If section header already in file, follow-up edit is allowed without header in new_string
printf '## developer-phoenix-backend Section\n\nExisting content\n' >"$LOG_FILE"
FIXTURE_FOLLOWUP=$(jq -n \
    --arg fp "$LOG_FILE" \
    --arg ns "Additional content" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"Existing content","new_string":"Additional content"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "follow-up edit when section already exists allows" "0" "$FIXTURE_FOLLOWUP"

# Test 4: Write to a NEW session log file with header in content — ALLOW
NEW_LOG_FILE="$TMP_DIR/codegen/logging/new-session.md"
WRITE_CONTENT_OK=$(printf '# Step\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE_WRITE_OK=$(jq -n \
    --arg fp "$NEW_LOG_FILE" \
    --arg c "$WRITE_CONTENT_OK" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp,"content":$c},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "developer-phoenix-backend Write with section header allows" "0" "$FIXTURE_WRITE_OK"

# Test 5: Write to a NEW session log file WITHOUT header in content — BLOCK
WRITE_CONTENT_BAD="# Step\n\nNo header here"
FIXTURE_WRITE_BAD=$(jq -n \
    --arg fp "$TMP_DIR/codegen/logging/another.md" \
    --arg c "$WRITE_CONTENT_BAD" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp,"content":$c},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "developer-phoenix-backend Write without section header blocks" "2" "$FIXTURE_WRITE_BAD"

# Test 6: planner Edit without "## planner Section" — ALLOW (planner writes ## Plan, not a Section header)
PLANNER_LOG="$TMP_DIR/codegen/logging/planner-session.md"
touch "$PLANNER_LOG"
FIXTURE_PLANNER_EDIT=$(jq -n \
    --arg fp "$PLANNER_LOG" \
    --arg ns "## Plan\n\nStep 1: do thing" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"","new_string":$ns},"agent_type":"planner","agent_id":"abc"}')
run_test "planner Edit without section header allows" "0" "$FIXTURE_PLANNER_EDIT"

# Test 7: planner Write without "## planner Section" — ALLOW
FIXTURE_PLANNER_WRITE=$(jq -n \
    --arg fp "$TMP_DIR/codegen/logging/planner-new.md" \
    --arg c "# Session Log\n\n## Plan\n\nDo stuff" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp,"content":$c},"agent_type":"planner","agent_id":"abc"}')
run_test "planner Write without section header allows" "0" "$FIXTURE_PLANNER_WRITE"

# Test 8: MultiEdit on session log with section header in one edit's new_string — ALLOW
MULTI_EDIT_LOG="$TMP_DIR/codegen/logging/multi.md"
touch "$MULTI_EDIT_LOG"
FIXTURE_MULTIEDIT_ALLOW=$(jq -n \
    --arg fp "$MULTI_EDIT_LOG" \
    '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":"x","new_string":"## developer-phoenix-backend Section\n\nbody"}]},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "developer-phoenix-backend MultiEdit with section header allows" "0" "$FIXTURE_MULTIEDIT_ALLOW"

# Test 9: MultiEdit on session log WITHOUT section header — BLOCK
FIXTURE_MULTIEDIT_BLOCK=$(jq -n \
    --arg fp "$MULTI_EDIT_LOG" \
    '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":"x","new_string":"no header here"}]},"agent_type":"developer-phoenix-backend","agent_id":"abc"}')
run_test "developer-phoenix-backend MultiEdit without section header blocks" "2" "$FIXTURE_MULTIEDIT_BLOCK"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
