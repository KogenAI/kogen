#!/bin/bash
# static-site-ex-guard_test.sh — unit tests for static-site-ex-guard.sh
#
# Tests:
#   1. Writing a .ex file is BLOCKED for static-site-developer (exit 2)
#   2. Writing a .js file PASSES for static-site-developer (exit 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/static-site-ex-guard.sh"

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

# Test 1: Writing a .ex file is BLOCKED for static-site-developer
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/app/lib/my_app/context.ex","content":"x"},"agent_type":"static-site-developer","agent_id":"abc123"}'
run_test ".ex file write blocked for static-site-developer" "2" "$FIXTURE_BLOCK"

# Test 2: Writing a .js file PASSES for static-site-developer
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/app/assets/app.js","content":"x"},"agent_type":"static-site-developer","agent_id":"abc123"}'
run_test ".js file write passes for static-site-developer" "0" "$FIXTURE_ALLOW"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
