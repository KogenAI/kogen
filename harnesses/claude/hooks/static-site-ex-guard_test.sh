#!/bin/bash
# static-site-ex-guard_test.sh — unit tests for static-site-ex-guard.sh
#
# Tests:
#   1. Writing a .ex file is BLOCKED for developer-html (exit 2)
#   2. Writing a .js file PASSES for developer-html (exit 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/static-site-ex-guard.sh"

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
        printf 'PASS: %s
' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: Writing a .ex file is BLOCKED for developer-html
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/app/lib/my_app/context.ex","content":"x"},"agent_type":"developer-html","agent_id":"abc123"}'
run_test ".ex file write blocked for developer-html" "2" "$FIXTURE_BLOCK"

# Test 2: Writing a .js file PASSES for developer-html
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/app/assets/app.js","content":"x"},"agent_type":"developer-html","agent_id":"abc123"}'
run_test ".js file write passes for developer-html" "0" "$FIXTURE_ALLOW"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
