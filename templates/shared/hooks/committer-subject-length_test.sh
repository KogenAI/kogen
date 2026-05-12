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

# 49-byte message — ALLOW
MSG_49="Add user auth with JWT tokens (49 chars)"
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_49"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with 49-byte message allows" "0" "$FIXTURE_ALLOW"

# 53-byte message — BLOCK
MSG_51="Add user auth feature with really long commit message"
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_51"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with 51-byte message blocks" "2" "$FIXTURE_BLOCK"

# Non-committer agent — not gated by this hook (pre-commit-guard handles it)
FIXTURE_OTHER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"some message\""},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "non-committer git commit not gated by this hook" "0" "$FIXTURE_OTHER"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
