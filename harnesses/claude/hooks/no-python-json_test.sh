#!/bin/bash
# no-python-json_test.sh — unit tests for no-python-json.sh
#
# Tests:
#   1: python3 -c "import json; ..." → deny
#   2: python -c "...json.load..." → deny
#   3: python3 -c 'import json,sys; print(json.load(sys.stdin))' → deny
#   4: python3 script.py → allow
#   5: python3 -c "print(1)" → allow
#   6: non-Bash tool → allow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/no-python-json.sh"

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

run_test "python3 -c import json blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python3 -c \"import json; print(json.load(open(p)))\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "python -c json.load blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python -c \"import sys,json; d=json.load(sys.stdin); print(d)\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "python3 -c piped json parse blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.json | python3 -c \"import json,sys; print(json.load(sys.stdin))\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "python3 script.py allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python3 script.py --foo"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "python3 -c print(1) allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python3 -c \"print(1)\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "non-Bash tool allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"python3 -c \"import json\""},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
