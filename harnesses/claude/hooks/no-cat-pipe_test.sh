#!/bin/bash
# no-cat-pipe_test.sh — unit tests for no-cat-pipe.sh
#
# Tests:
#   1: cat file | head → deny
#   2: cat file | tail → deny
#   3: cat file | grep foo → deny
#   4: cat file | less → deny
#   5: cat file | more → deny
#   6: cat file.txt → allow (no pipe)
#   7: echo x | cat → allow (cat is consumer, not source)
#   8: cat <<EOF heredoc → allow
#   9: cat a.txt b.txt → allow (multi-file, no pipe)
#  10: non-Bash tool → allow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/no-cat-pipe.sh"

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

run_test "cat file | head blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | head -50"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | tail blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | tail -20"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | grep blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | grep bar"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | less blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | less"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file | more blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | more"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat file alone allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "echo x | cat allowed (cat is consumer)" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hello | cat"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat heredoc allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat <<EOF\nhello\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "cat multi-file no pipe allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat a.txt b.txt"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

run_test "non-Bash tool allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"cat foo | head"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
