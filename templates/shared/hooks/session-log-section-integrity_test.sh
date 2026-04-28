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

LOG_FILE="$TMP_DIR/codegen/logging/foo.md"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Test 1: phoenix-developer Edit with section header in new_string — ALLOW
NEW_WITH_HEADER=$(printf '## phoenix-developer Section\n\nSome content')
FIXTURE_ALLOW=$(jq -n \
    --arg fp "$LOG_FILE" \
    --arg ns "$NEW_WITH_HEADER" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"","new_string":$ns},"agent_type":"phoenix-developer","agent_id":"abc"}')
run_test "phoenix-developer Edit with section header allows" "0" "$FIXTURE_ALLOW"

# Test 2: phoenix-developer Edit without section header — BLOCK
NEW_WITHOUT_HEADER="Some content without the required header"
FIXTURE_BLOCK=$(jq -n \
    --arg fp "$LOG_FILE" \
    --arg ns "$NEW_WITHOUT_HEADER" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"","new_string":$ns},"agent_type":"phoenix-developer","agent_id":"abc"}')
run_test "phoenix-developer Edit without section header blocks" "2" "$FIXTURE_BLOCK"

# Test 3: If section header already in file, follow-up edit is allowed without header in new_string
printf '## phoenix-developer Section\n\nExisting content\n' >"$LOG_FILE"
FIXTURE_FOLLOWUP=$(jq -n \
    --arg fp "$LOG_FILE" \
    --arg ns "Additional content" \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"Existing content","new_string":"Additional content"},"agent_type":"phoenix-developer","agent_id":"abc"}')
run_test "follow-up edit when section already exists allows" "0" "$FIXTURE_FOLLOWUP"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
