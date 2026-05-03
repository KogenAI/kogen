#!/bin/bash
# codex-inspector-write-guard_test.sh — unit tests for codex-inspector-write-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/codex-inspector-write-guard.sh"

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

# Test 1: apply_patch — BLOCK
FIXTURE_APPLY='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/file\n+++ b/file"}}'
run_test "apply_patch is blocked" "2" "$FIXTURE_APPLY"

# Test 2: unrelated tool name — ALLOW
FIXTURE_SHELL='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"git log --oneline"}}'
run_test "shell tool is allowed" "0" "$FIXTURE_SHELL"

# Test 3: empty tool name — ALLOW
FIXTURE_EMPTY='{"hook_event_name":"PreToolUse","tool_name":"","tool_input":{}}'
run_test "empty tool name is allowed" "0" "$FIXTURE_EMPTY"

# Test 4: read-only tool — ALLOW
FIXTURE_READ='{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_input":{"path":"/tmp/foo"}}'
run_test "read_file tool is allowed" "0" "$FIXTURE_READ"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
