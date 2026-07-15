#!/bin/bash
# committer-single-commit-per-cycle_test.sh — unit tests
#
# Tests:
#   1. AGENT_TYPE not committer → allow
#   2. COMMITTER_ALLOW_MULTI=1 → allow (escape hatch)
#   3. CODEGEN_CYCLE_BASE_SHA unset → allow (not a build context)
#   4. Tool call is not git commit (e.g., git status) → allow
#   5. --amend → allow (cycle commit exists ahead of base)
#   6. First commit, base == HEAD (nothing committed yet this cycle) → allow
#   7. Second non-amend commit (a commit already exists ahead of base) → deny
#   8. --amend when HEAD == base (nothing to amend within this cycle) → deny
#   9. codegen-log write narrating "git commit" in heredoc body → allow
#  10. real standalone git commit still denied unchanged
#  11. earlier-role commit (base captured before an earlier role committed) → deny
#      (the reported defect: CODEGEN_CYCLE_BASE_SHA is cycle-stable, so a
#      commit made by an EARLIER role in the same cycle is still counted,
#      unlike the old per-role CODEGEN_BUILD_START_TS timestamp window)

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
    "CODEGEN_CYCLE_BASE_SHA=deadbeef"

# --- Test 2: COMMITTER_ALLOW_MULTI=1 → allow ---
# Needs a git repo + a commit ahead of base to prove the escape hatch fires before the deny
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
)
BASE_SHA_EARLY=$(git -C "$TMP_EARLY" rev-parse HEAD)
(
    cd "$TMP_EARLY"
    echo "updated" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "cycle commit"
)

run_test "COMMITTER_ALLOW_MULTI=1 → allow (escape hatch)" "0" \
    "$(commit_fixture "committer" "$TMP_EARLY")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA_EARLY" "COMMITTER_ALLOW_MULTI=1" "CLAUDE_PROJECT_DIR=$TMP_EARLY"

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

# --- Tests 5-8, 10: require a real git repo with base + one cycle commit ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP_EARLY" "$TMP"' EXIT

(
    cd "$TMP"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"

    # Baseline commit (pre-cycle — this is CODEGEN_CYCLE_BASE_SHA)
    echo "original content" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline commit"
)
BASE_SHA=$(git -C "$TMP" rev-parse HEAD)
(
    cd "$TMP"
    # Cycle commit (made during the build cycle, ahead of base)
    echo "updated content" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "cycle commit"
)

# --- Test 5: --amend → allow (a cycle commit exists ahead of base) ---
run_test "--amend → allow (amend existing cycle commit)" "0" \
    "$(amend_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 6: First commit — base == HEAD (nothing committed yet this cycle) → allow ---
HEAD_SHA=$(git -C "$TMP" rev-parse HEAD)
run_test "first commit (base == HEAD, no cycle commits yet) → allow" "0" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$HEAD_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 7: Second non-amend commit (a cycle commit already exists) → deny ---
run_test "second non-amend commit (cycle commit exists) → deny" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 8: --amend when HEAD == base (nothing to amend within this cycle) → deny ---
run_test "--amend when HEAD == base → deny (nothing to amend this cycle)" "2" \
    "$(amend_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$HEAD_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 9: codegen-log write narrating "git commit" in heredoc body → allow ---
# A cycle commit already exists in $TMP; a real git commit would be denied
# (see Test 7), but a codegen-log write narrating it must be allowed.
log_write_fixture() {
    jq -n \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m \"msg\" successfully.\nEOF"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "codegen-log write narrating git commit → allow" "0" \
    "$(log_write_fixture)" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 10: real standalone git commit still denied unchanged (cycle commit exists) ---
run_test "real git commit still denied unchanged" "2" \
    "$(commit_fixture "committer" "$TMP")" \
    "CODEGEN_CYCLE_BASE_SHA=$BASE_SHA" "CLAUDE_PROJECT_DIR=$TMP"

# --- Test 11: earlier-role commit — base captured at cycle start, an EARLIER
# role already committed once (evading pre-commit-guard or otherwise) before
# the committer's own turn. CODEGEN_CYCLE_BASE_SHA is identical across every
# role's env (unlike the old per-role CODEGEN_BUILD_START_TS), so this
# earlier commit IS counted and the committer's second commit is denied.
TMP_EARLIER_ROLE=$(mktemp -d)
trap 'rm -rf "$TMP_EARLY" "$TMP" "$TMP_EARLIER_ROLE"' EXIT
(
    cd "$TMP_EARLIER_ROLE"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "original" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "cycle base commit"
)
CYCLE_BASE_FOR_T11=$(git -C "$TMP_EARLIER_ROLE" rev-parse HEAD)
(
    cd "$TMP_EARLIER_ROLE"
    echo "changed by an earlier role" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "earlier-role commit"
)
run_test "earlier-role commit (same cycle base) → second commit denied" "2" \
    "$(commit_fixture "committer" "$TMP_EARLIER_ROLE")" \
    "CODEGEN_CYCLE_BASE_SHA=$CYCLE_BASE_FOR_T11" "CLAUDE_PROJECT_DIR=$TMP_EARLIER_ROLE"

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
