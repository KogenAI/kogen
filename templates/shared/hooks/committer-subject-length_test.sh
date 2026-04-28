#!/bin/bash
# committer-subject-length_test.sh — unit tests for committer-subject-length.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-subject-length.sh"

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

# 49-byte message — ALLOW
MSG_49="Add user auth with JWT tokens (49 chars)"
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_49"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with 49-byte message allows" "0" "$FIXTURE_ALLOW"

# 53-byte message — BLOCK
MSG_51="Add user auth feature with really long commit message"
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_51"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with 51-byte message blocks" "2" "$FIXTURE_BLOCK"

# Non-committer agent — not gated by this hook (commit-only-via-committer handles it)
FIXTURE_OTHER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"some message\""},"agent_type":"phoenix-developer","agent_id":"abc"}'
run_test "non-committer git commit not gated by this hook" "0" "$FIXTURE_OTHER"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
