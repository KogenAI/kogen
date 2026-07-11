#!/bin/bash
# committer-no-revert-prior-commit_test.sh — unit tests
#
# Tests:
#   1. AGENT_TYPE not committer → allow
#   2. COMMITTER_ALLOW_REVERT=1 → allow (escape hatch)
#   3. CODEGEN_BUILD_START_TS unset → allow (not a build context)
#   4. No session commits (build_start far in future) → allow
#   5. Staged content does NOT equal any superseded ancestor → allow
#   6. Staged content equals a superseded ancestor → deny
#   7. Tool call is not git commit (e.g., git status) → allow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-no-revert-prior-commit.sh"

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

# Helper: build JSON fixture for a git commit tool call with optional cwd
# Note: use jq to build valid JSON so embedded quotes are handled safely.
commit_fixture() {
    local agent_type="${1:-committer}"
    local cwd="${2:-}"
    if [ -n "$cwd" ]; then
        jq -n --arg at "$agent_type" --arg cwd "$cwd" \
            '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m test"},"agent_type":$at,"agent_id":"abc","cwd":$cwd}'
    else
        jq -n --arg at "$agent_type" \
            '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m test"},"agent_type":$at,"agent_id":"abc"}'
    fi
}

# Helper: build JSON fixture for a non-commit command
status_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"committer","agent_id":"abc"}'
}

# --- Test 1: AGENT_TYPE not committer → allow ---
run_test "non-committer agent → allow" "0" \
    "$(commit_fixture "developer-phoenix-backend")" \
    "CODEGEN_BUILD_START_TS=1000000"

# --- Test 2: COMMITTER_ALLOW_REVERT=1 → allow ---
run_test "COMMITTER_ALLOW_REVERT=1 → allow (escape hatch)" "0" \
    "$(commit_fixture "committer")" \
    "CODEGEN_BUILD_START_TS=1000000" "COMMITTER_ALLOW_REVERT=1"

# --- Test 3: CODEGEN_BUILD_START_TS unset → allow ---
run_test "CODEGEN_BUILD_START_TS unset → allow" "0" \
    "$(commit_fixture "committer")"

# --- Test 4: git status (not git commit) → allow ---
run_test "git status → allow (not a commit)" "0" \
    "$(status_fixture)" \
    "CODEGEN_BUILD_START_TS=1000000"

# --- Test 4a: git commit-graph (not git commit) → allow (word-boundary fix) ---
commit_graph_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-graph write"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "git commit-graph → allow (word-boundary fix)" "0" \
    "$(commit_graph_fixture)" \
    "CODEGEN_BUILD_START_TS=1000000"

# --- Test 4b: git commit-tree (not git commit) → allow (word-boundary fix) ---
commit_tree_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-tree abc123 -m msg"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "git commit-tree → allow (word-boundary fix)" "0" \
    "$(commit_tree_fixture)" \
    "CODEGEN_BUILD_START_TS=1000000"

# --- Tests 5-7: require a real git repo ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
git config user.email "test@example.com"
git config user.name "Test"

# Initial commit (baseline — pre-session state)
echo "original content" >file.txt
git add file.txt
git -c core.hooksPath=/dev/null commit -q -m "baseline commit"

# Session commit: update file.txt (made during the build session)
echo "updated content" >file.txt
git add file.txt
git -c core.hooksPath=/dev/null commit -q -m "session commit: update file"

# --- Test 5: no session commits in build window (build_start far in future) → allow ---
# Stage forward content, but build_start is in the far future so no session commits exist
SESSION_COMMIT_TS=$(git log -1 --format="%ct")
FUTURE_TS=$((SESSION_COMMIT_TS + 3600))

echo "new content after session" >file.txt
git add file.txt

run_test "no session commits in build window → allow" "0" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=$FUTURE_TS" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 6: staged content equals superseded ancestor → deny ---
# BUILD_START_TS=0 ensures all commits qualify as session commits.
# Stage the original (pre-session-commit) content — this is a backward roll.
git checkout -- file.txt # restore to "updated content" (HEAD)
echo "original content" >file.txt
git add file.txt

run_test "staged content reverts session commit → deny" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 7: staged content is forward progress → allow ---
git checkout -- file.txt # restore to "updated content" (HEAD)
echo "further progress beyond session commit" >file.txt
git add file.txt

run_test "staged content is forward progress → allow" "0" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 8: codegen-log write narrating "git commit" in heredoc body → allow ---
# Backward-roll content is still staged from Test 6; a real commit would be
# denied (see Test 6), but a codegen-log write narrating it must be allowed.
log_write_fixture() {
    jq -n \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m \"msg\" successfully.\nEOF"},"agent_type":"committer","agent_id":"abc"}'
}
git checkout -- file.txt # restore to "updated content" (HEAD)
echo "original content" >file.txt
git add file.txt
run_test "codegen-log write narrating git commit → allow" "0" \
    "$(log_write_fixture)" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 9: real staged backward-roll commit still denied unchanged ---
run_test "real backward-roll commit still denied unchanged" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
