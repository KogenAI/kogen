#!/bin/bash
# committer-no-trailer-guard_test.sh — unit tests for committer-no-trailer-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-no-trailer-guard.sh"

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

COMMITTER='committer'
BACKEND='developer-phoenix-backend'

# 1. bare git commit → BLOCK
run_test "bare git commit BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 2. git commit -m "msg" → ALLOW
run_test "git commit -m msg ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"Add feature\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 3. git commit --amend -m "msg" → ALLOW
run_test "git commit --amend -m msg ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend -m \\\"Fix typo\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 4. git commit --file COMMIT_MSG → BLOCK
run_test "git commit --file BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --file /tmp/msg.txt\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 5. git commit -F /tmp/msg.txt → BLOCK
run_test "git commit -F BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -F /tmp/msg.txt\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 6. non-committer agent → ALLOW (pass-through)
run_test "non-committer git commit allowed (not this hook's job)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit\"},\"agent_type\":\"$BACKEND\",\"agent_id\":\"abc\"}"

# 7. non-git command for committer → ALLOW
run_test "committer non-git-commit bash allowed" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 8. git commit -m with single quotes → ALLOW
run_test "git commit -m single-quoted msg ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m 'Add thing'\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 9. codegen-log write narrating bare "git commit" (no -m) in heredoc body → ALLOW
run_test "codegen-log write narrating bare git commit ALLOWED" "0" \
    "$(jq -n --arg at "$COMMITTER" '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan bare git commit — denied by trailer guard, as expected.\nEOF"},"agent_type":$at,"agent_id":"abc"}')"

# 10. real standalone bare git commit still BLOCKED unchanged
run_test "bare git commit still BLOCKED unchanged" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
