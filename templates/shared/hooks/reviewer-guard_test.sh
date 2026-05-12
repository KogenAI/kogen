#!/bin/bash
# reviewer-guard_test.sh — unit tests for reviewer-guard.sh
#
# Tests:
#   1. Bash tool is BLOCKED for reviewer-phoenix (deny envelope)
#   2. Bash tool is BLOCKED for reviewer-static  (deny envelope)
#   3. Bash tool PASSES for developer-phoenix-backend (allow)

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

FIXTURE_PHOENIX='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"reviewer-phoenix","agent_id":"abc123"}'
run_test "Bash blocked for reviewer-phoenix" "2" "$FIXTURE_PHOENIX"

FIXTURE_STATIC='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm run build"},"agent_type":"reviewer-static","agent_id":"abc123"}'
run_test "Bash blocked for reviewer-static" "2" "$FIXTURE_STATIC"

FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mix test"},"agent_type":"developer-phoenix-backend","agent_id":"abc123"}'
run_test "Bash passes for developer-phoenix-backend" "0" "$FIXTURE_ALLOW"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
