#!/bin/bash
# committer-no-revert-prior-commit_test.sh — unit tests
#
# Tests:
#   1. AGENT_TYPE not committer → allow
#   2. COMMITTER_ALLOW_REVERT=1 → allow (escape hatch)
#   3. CODEGEN_CYCLE_BASE_SHA unset → allow (not a build context)
#   4. No cycle commits (base == HEAD) → allow
#   5. Staged content does NOT equal any superseded ancestor → allow
#   6. Staged content equals a superseded ancestor → deny
#   7. Tool call is not git commit (e.g., git status) → allow
#   8. codegen-log write narrating "git commit" in heredoc body → allow
#   9. real staged backward-roll commit still denied unchanged
#  10. base-SHA-driven session-commit enumeration sees an EARLIER role's
#      commit (cycle-stable base, unlike the old per-role
#      CODEGEN_BUILD_START_TS window) → backward roll against it still denied

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
        stdout=$(printf '%s' "$input" | env -u CODEGEN_BUILD_START_TS -u CODEGEN_CYCLE_BASE_SHA "${env_args[@]}" bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | env -u CODEGEN_BUILD_START_TS -u CODEGEN_CYCLE_BASE_SHA bash "$GUARD" 2>/dev/null || true)
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
    "CODEGEN_CYCLE_BASE_SHA=deadbeef"

# --- Test 2: COMMITTER_ALLOW_REVERT=1 → allow ---
run_test "COMMITTER_ALLOW_REVERT=1 → allow (escape hatch)" "0" \
    "$(commit_fixture "committer")" \
    "CODEGEN_CYCLE_BASE_SHA=deadbeef" "COMMITTER_ALLOW_REVERT=1"

# --- Test 3: CODEGEN_CYCLE_BASE_SHA unset → allow ---
run_test "CODEGEN_CYCLE_BASE_SHA unset → allow" "0" \
    "$(commit_fixture "committer")"

# --- Test 4: git status (not git commit) → allow ---
run_test "git status → allow (not a commit)" "0" \
    "$(status_fixture)" \
    "CODEGEN_CYCLE_BASE_SHA=deadbeef"

# --- Test 4a: git commit-graph (not git commit) → allow (word-boundary fix) ---
commit_graph_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-graph write"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "git commit-graph → allow (word-boundary fix)" "0" \
    "$(commit_graph_fixture)" \
    "CODEGEN_CYCLE_BASE_SHA=deadbeef"

# --- Test 4b: git commit-tree (not git commit) → allow (word-boundary fix) ---
commit_tree_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-tree abc123 -m msg"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "git commit-tree → allow (word-boundary fix)" "0" \
    "$(commit_tree_fixture)" \
    "CODEGEN_CYCLE_BASE_SHA=deadbeef"

# --- Tests 5-9: require a real git repo ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
git config user.email "test@example.com"
git config user.name "Test"

# Initial commit (baseline — this is CODEGEN_CYCLE_BASE_SHA, pre-cycle state)
echo "original content" >file.txt
git add file.txt
git -c core.hooksPath=/dev/null commit -q -m "baseline commit"
BASE_SHA=$(git rev-parse HEAD)

# Cycle commit: update file.txt (made during the build cycle, ahead of base)
echo "updated content" >file.txt
git add file.txt
git -c core.hooksPath=/dev/null commit -q -m "cycle commit: update file"

# --- Test 5: no cycle commits (base == HEAD) → allow ---
# Stage forward content, but base == current HEAD so no cycle commits exist yet.
HEAD_SHA=$(git rev-parse HEAD)

echo "new content after cycle" >file.txt
git add file.txt

run_test "no cycle commits (base == HEAD) → allow" "0" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$HEAD_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 6: staged content equals superseded ancestor → deny ---
# base_sha=$BASE_SHA ensures the cycle commit qualifies as a session commit.
# Stage the original (pre-cycle-commit) content — this is a backward roll.
git checkout -- file.txt # restore to "updated content" (HEAD)
echo "original content" >file.txt
git add file.txt

run_test "staged content reverts cycle commit → deny" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 7: staged content is forward progress → allow ---
git checkout -- file.txt # restore to "updated content" (HEAD)
echo "further progress beyond cycle commit" >file.txt
git add file.txt

run_test "staged content is forward progress → allow" "0" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

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
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 9: real staged backward-roll commit still denied unchanged ---
run_test "real backward-roll commit still denied unchanged" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 10: base-SHA-driven enumeration sees an EARLIER role's commit ---
# A fresh repo where "base" is captured at cycle start (before any role ran).
# An EARLIER role then made a commit (e.g. via an evaded pre-commit-guard
# bypass) that this hook must still recognize as a "session commit" via the
# cycle-stable base — unlike the old per-role CODEGEN_BUILD_START_TS window,
# which would have missed a commit made before the committer's own turn.
TMP2=$(mktemp -d)
trap 'rm -rf "$TMP" "$TMP2"' EXIT
(
    cd "$TMP2"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "original" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "cycle base commit"
)
CYCLE_BASE_FOR_T10=$(git -C "$TMP2" rev-parse HEAD)
(
    cd "$TMP2"
    echo "changed by an earlier role" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "earlier-role commit"
)
(
    cd "$TMP2"
    # committer now stages a backward roll against the earlier role's commit
    git checkout -- file.txt
    echo "original" >file.txt
    git add file.txt
)
run_test "earlier-role commit recognized via cycle-stable base → backward roll denied" "2" \
    "$(commit_fixture "committer" "$TMP2")" \
    "CODEGEN_CYCLE_BASE_SHA=$CYCLE_BASE_FOR_T10" "CLAUDE_PROJECT_DIR=$TMP2"

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
