#!/bin/bash
# ve-gate-prompt-validator_test.sh — unit tests for ve-gate-prompt-validator.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/ve-gate-prompt-validator.sh"

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

# Test 1: SubagentStart with prompt starting "Gate: make ci\n..." — ALLOW
# Use JSON-escaped \n (literal backslash-n in JSON = newline in parsed string)
FIXTURE_ALLOW='{"hook_event_name":"SubagentStart","agent_type":"verification-engineer","agent_id":"abc","prompt":"Gate: make ci\nSome other stuff"}'
run_test "prompt starting Gate: allows" "0" "$FIXTURE_ALLOW"

# Test 2: SubagentStart with prompt "make ci\nGate: ..." — BLOCK (Gate not first)
FIXTURE_BLOCK='{"hook_event_name":"SubagentStart","agent_type":"verification-engineer","agent_id":"abc","prompt":"make ci\nGate: make ci"}'
run_test "prompt without Gate on first line blocks" "2" "$FIXTURE_BLOCK"

# Test 3: Prompt with empty first line then "Gate: ..." — ALLOW (first non-empty line is Gate:)
FIXTURE_BLANK='{"hook_event_name":"SubagentStart","agent_type":"verification-engineer","agent_id":"abc","prompt":"\nGate: make ci\nblah"}'
run_test "blank first line then Gate: allows" "0" "$FIXTURE_BLANK"

# Test 4: Non-VE agent — ALLOW unconditionally
FIXTURE_OTHER='{"hook_event_name":"SubagentStart","agent_type":"phoenix-developer","agent_id":"abc","prompt":"make ci"}'
run_test "non-VE agent allows unconditionally" "0" "$FIXTURE_OTHER"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
