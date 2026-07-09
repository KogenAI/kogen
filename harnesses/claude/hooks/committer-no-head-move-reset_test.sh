#!/bin/bash
# committer-no-head-move-reset_test.sh — unit tests
#
# Tests:
#   1. AGENT_TYPE not committer → allow
#   2. TOOL_NAME not Bash → allow
#   3. COMMITTER_ALLOW_MULTI=1 → allow (escape hatch)
#   4. git status (not git reset) → allow
#   5. bare `git reset` → allow
#   6. `git reset HEAD` → allow
#   7. `git reset -- path` → allow
#   8. `git reset HEAD -- path` → allow
#   9. `git reset HEAD~1` → deny
#  10. `git reset --hard HEAD~1` → deny
#  11. `git reset --soft HEAD^` → deny
#  12. `git reset <40-hex-sha>` → deny
#  13. `git reset --keep origin/develop` → deny
#  14. codegen-log write narrating "git reset HEAD~1" in heredoc body → allow (bypass)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-no-head-move-reset.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    shift 3
    local env_args=()
    for kv in "$@"; do
        env_args+=("$kv")
    done

    local stdout
    if [ ${#env_args[@]} -gt 0 ]; then
        stdout=$(printf '%s' "$input" | env "${env_args[@]}" bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)
    fi

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

# Helper: build JSON fixture for an arbitrary command with optional agent_type
cmd_fixture() {
    local command="$1"
    local agent_type="${2:-committer}"
    local tool_name="${3:-Bash}"
    jq -n --arg cmd "$command" --arg at "$agent_type" --arg tn "$tool_name" \
        '{"hook_event_name":"PreToolUse","tool_name":$tn,"tool_input":{"command":$cmd},"agent_type":$at,"agent_id":"abc"}'
}

# --- Test 1: AGENT_TYPE not committer → allow ---
run_test "non-committer agent → allow" "0" \
    "$(cmd_fixture "git reset HEAD~1" "developer-phoenix-backend")"

# --- Test 2: TOOL_NAME not Bash → allow ---
run_test "non-Bash tool → allow" "0" \
    "$(cmd_fixture "git reset HEAD~1" "committer" "Edit")"

# --- Test 3: COMMITTER_ALLOW_MULTI=1 → allow (escape hatch) ---
run_test "COMMITTER_ALLOW_MULTI=1 → allow (escape hatch)" "0" \
    "$(cmd_fixture "git reset HEAD~1")" \
    "COMMITTER_ALLOW_MULTI=1"

# --- Test 4: git status (not git reset) → allow ---
run_test "git status → allow (not a reset)" "0" \
    "$(cmd_fixture "git status")"

# --- Test 5: bare git reset → allow ---
run_test "bare git reset → allow" "0" \
    "$(cmd_fixture "git reset")"

# --- Test 6: git reset HEAD → allow ---
run_test "git reset HEAD → allow" "0" \
    "$(cmd_fixture "git reset HEAD")"

# --- Test 7: git reset -- path → allow ---
run_test "git reset -- path.txt → allow" "0" \
    "$(cmd_fixture "git reset -- path.txt")"

# --- Test 8: git reset HEAD -- path → allow ---
run_test "git reset HEAD -- path.txt → allow" "0" \
    "$(cmd_fixture "git reset HEAD -- path.txt")"

# --- Test 9: git reset HEAD~1 → deny ---
run_test "git reset HEAD~1 → deny" "2" \
    "$(cmd_fixture "git reset HEAD~1")"

# --- Test 10: git reset --hard HEAD~1 → deny ---
run_test "git reset --hard HEAD~1 → deny" "2" \
    "$(cmd_fixture "git reset --hard HEAD~1")"

# --- Test 11: git reset --soft HEAD^ → deny ---
run_test "git reset --soft HEAD^ → deny" "2" \
    "$(cmd_fixture "git reset --soft HEAD^")"

# --- Test 12: git reset <40-hex-sha> → deny ---
run_test "git reset <sha> → deny" "2" \
    "$(cmd_fixture "git reset abc1234567890123456789012345678901234567")"

# --- Test 13: git reset --keep origin/develop → deny ---
run_test "git reset --keep origin/develop → deny" "2" \
    "$(cmd_fixture "git reset --keep origin/develop")"

# --- Test 14: codegen-log write narrating "git reset HEAD~1" in heredoc body → allow (bypass) ---
log_write_fixture() {
    jq -n \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git reset HEAD~1 successfully.\nEOF"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "codegen-log write narrating git reset HEAD~1 → allow" "0" \
    "$(log_write_fixture)"

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
