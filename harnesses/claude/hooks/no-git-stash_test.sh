#!/bin/bash
# no-git-stash_test.sh — unit tests for no-git-stash.sh
#
# Tests:
#   1: git stash → deny
#   2: git stash push → deny
#   3: git stash pop → deny
#   4: git stash list → deny
#   5: git status → allow
#   6: git log --stash → allow (not a stash subcommand)
#   7: Read tool with `git stash` command → allow (non-Bash)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/no-git-stash.sh"

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

# Test 1: git stash → deny
run_test "git stash blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 2: git stash push → deny
run_test "git stash push blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash push -m wip"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 3: git stash pop → deny
run_test "git stash pop blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash pop"},"agent_type":"orchestrator","agent_id":"a"}'

# Test 4: git stash list → deny
run_test "git stash list blocked" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash list"},"agent_type":"committer","agent_id":"a"}'

# Test 5: git status → allow
run_test "git status allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 6: git log --stash → allow (not a stash subcommand)
run_test "git log --stash allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log --stash"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 7: Read tool → allow (non-Bash)
run_test "Read tool with git stash payload allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"git stash"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 8: codegen-log write narrating "git stash" in heredoc body → allow
run_test "codegen-log write narrating git stash allowed" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## developer-phoenix-backend Section\nDid NOT run git stash — used a scratch branch instead.\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

# Test 9: real standalone git stash still blocked unchanged
run_test "real git stash still blocked (unchanged)" "2" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git stash"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
