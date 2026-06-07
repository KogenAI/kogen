#!/bin/bash
# committer-single-line-guard_test.sh — unit tests for committer-single-line-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-single-line-guard.sh"

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

# 1. Single-line -m → ALLOW
run_test "single-line -m ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"Add feature\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 2. -m with literal \n (two chars) → BLOCK
run_test "-m with literal backslash-n BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"Add feature\\\\ndetails\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 3. No -m flag → ALLOW (pass-through, no-trailer-guard handles)
run_test "bare git commit (no -m) ALLOWED by this hook" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 4. Non-committer → ALLOW
run_test "non-committer ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"bad\\\\nmsg\\\"\"},\"agent_type\":\"$BACKEND\",\"agent_id\":\"abc\"}"

# 5. -m with actual embedded newline via jq → BLOCK
MULTILINE_CMD=$(jq -n '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"Add feature\ndetails\""},"agent_type":"committer","agent_id":"abc"}')
run_test "-m with actual embedded newline BLOCKED" "2" "$MULTILINE_CMD"

# 6. Non-bash tool for committer → ALLOW
run_test "non-Bash tool ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/tmp/foo\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 7. git commit --amend -m single-line → ALLOW
run_test "--amend -m single-line ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend -m \\\"Fix typo\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 8. git status (non-commit) → ALLOW
run_test "git status ALLOWED (not a commit)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
