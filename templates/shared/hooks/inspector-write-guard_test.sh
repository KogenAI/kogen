#!/bin/bash
# inspector-write-guard_test.sh — unit tests for inspector-write-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/inspector-write-guard.sh"

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

# Test 1: Write tool — BLOCK
FIXTURE_WRITE='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/foo.ex","content":"x"}}'
run_test "Write tool blocked" "2" "$FIXTURE_WRITE"

# Test 2: Edit tool — BLOCK
FIXTURE_EDIT='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.ex","old_string":"x","new_string":"y"}}'
run_test "Edit tool blocked" "2" "$FIXTURE_EDIT"

# Test 3: Read tool — ALLOW
FIXTURE_READ='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/foo.ex"}}'
run_test "Read tool allowed" "0" "$FIXTURE_READ"

# Test 4: Bash tool — ALLOW (not a write tool)
FIXTURE_BASH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_test "Bash tool allowed" "0" "$FIXTURE_BASH"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
