#!/bin/bash
# committer-single-commit-per-cycle_test.sh — unit tests
#
# Tests:
#   1. AGENT_TYPE not committer → allow
#   2. COMMITTER_ALLOW_MULTI=1 → allow (escape hatch)
#   3. CODEGEN_BUILD_START_TS unset → allow (not a build context)
#   4. Tool call is not git commit (e.g., git status) → allow
#   5. --amend → allow (even with a session commit present, when HEAD time ≥ start)
#   6. First commit, no session commits in build window (future build_start) → allow
#   7. Second non-amend commit (session commit already exists) → deny
#   8. --amend on a repo whose HEAD commit time < CODEGEN_BUILD_START_TS → deny

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-single-commit-per-cycle.sh"

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

# Helper: build JSON fixture for a git commit --amend tool call with optional cwd
amend_fixture() {
    local agent_type="${1:-committer}"
    local cwd="${2:-}"
    if [ -n "$cwd" ]; then
        jq -n --arg at "$agent_type" --arg cwd "$cwd" \
            '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit --amend -m test"},"agent_type":$at,"agent_id":"abc","cwd":$cwd}'
    else
        jq -n --arg at "$agent_type" \
            '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit --amend -m test"},"agent_type":$at,"agent_id":"abc"}'
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

# --- Test 2: COMMITTER_ALLOW_MULTI=1 → allow ---
# Needs a git repo + a session commit to prove the escape hatch fires before the deny
TMP_EARLY=$(mktemp -d)
trap 'rm -rf "$TMP_EARLY"' EXIT

(
    cd "$TMP_EARLY"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "file" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline"
    echo "updated" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "session commit"
)

run_test "COMMITTER_ALLOW_MULTI=1 → allow (escape hatch)" "0" \
    "$(commit_fixture "committer" "$TMP_EARLY")" \
    "CODEGEN_BUILD_START_TS=0" "COMMITTER_ALLOW_MULTI=1" "CLAUDE_PROJECT_DIR=$TMP_EARLY"

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

# --- Tests 5-7: require a real git repo with a session commit ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP_EARLY" "$TMP"' EXIT

(
    cd "$TMP"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"

    # Baseline commit (pre-session)
    echo "original content" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline commit"

    # Session commit (made during the build session)
    echo "updated content" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "session commit"
)

SESSION_COMMIT_TS=$(git -C "$TMP" log -1 --format="%ct")

# --- Test 5: --amend → allow (even when a session commit exists) ---
run_test "--amend → allow (amend existing commit)" "0" \
    "$(amend_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 6: First commit (build_start in future) → allow ---
FUTURE_TS=$((SESSION_COMMIT_TS + 3600))

run_test "first commit (no session commits in build window) → allow" "0" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=$FUTURE_TS" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 7: Second non-amend commit (session commit already exists) → deny ---
run_test "second non-amend commit (session commit exists) → deny" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 8: --amend on repo whose HEAD commit time < CODEGEN_BUILD_START_TS → deny ---
# The session commit in $TMP was made recently; set START_TS to HEAD_CT + 3600
# (1 hour in the future) so HEAD predates the "cycle start" — foreign amend denied.
HEAD_CT_FOR_T8="$(git -C "$TMP" log -1 --format="%ct")"
FUTURE_START_TS_FOR_T8=$((HEAD_CT_FOR_T8 + 3600))
run_test "--amend when HEAD predates cycle start → deny (foreign amend)" "2" \
    "$(amend_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=$FUTURE_START_TS_FOR_T8" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 9: codegen-log write narrating "git commit" in heredoc body → allow ---
# Session commit already exists in $TMP; a real git commit would be denied
# (see Test 7), but a codegen-log write narrating it must be allowed.
log_write_fixture() {
    jq -n \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m \"msg\" successfully.\nEOF"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "codegen-log write narrating git commit → allow" "0" \
    "$(log_write_fixture)" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 10: real standalone git commit still denied unchanged (session commit exists) ---
run_test "real git commit still denied unchanged" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_BUILD_START_TS=0" "CLAUDE_PROJECT_DIR=$TMP"

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
