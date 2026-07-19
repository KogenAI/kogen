#!/bin/bash
# committer-gate-verdict-clear_test.sh — unit tests
#
# Tests:
#   1. AGENT_TYPE not committer → allow
#   2. Tool call is not Bash → allow (n/a here; TOOL_NAME fixed by fixture)
#   3. codegen-log write narrating "git commit" in heredoc body → allow
#   4. Tool call does not contain git commit (e.g., git status) → allow
#   5. gate-result.json absent → deny
#   6. gate-result.json verdict=clear → allow
#   7. gate-result.json verdict=failed → deny
#   8. gate-result.json verdict=inconclusive → deny
#   9. gate-result.json malformed JSON → deny
#  10. git commit --amend, verdict=clear → allow
#  11. git commit --amend, verdict=failed → deny
#  12. git -C <dir> commit form, verdict=clear → allow
#  13. cd <dir> && git commit form, verdict=clear → allow
#  14. git commit-graph (word-boundary; not a real commit) → allow
#  15. deny message names the actual verdict value
#  16. payload cwd is a subdir of a git repo holding a clear gate-result at
#      the root → allow (git-toplevel anchor recovers the root)
#  17. outside any repo, gate-result absent → deny naming both resolved and
#      raw dirs
#  18. anchored git repo, genuinely absent gate-result → deny naming the
#      repo root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-gate-verdict-clear.sh"

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
    local cmd="${3:-git commit -m test}"
    if [ -n "$cwd" ]; then
        jq -n --arg at "$agent_type" --arg cwd "$cwd" --arg cmd "$cmd" \
            '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":$at,"agent_id":"abc","cwd":$cwd}'
    else
        jq -n --arg at "$agent_type" --arg cmd "$cmd" \
            '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":$at,"agent_id":"abc"}'
    fi
}

status_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_type":"committer","agent_id":"abc"}'
}

log_write_fixture() {
    jq -n \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codegen-log section --slug test --body @- <<EOF\n## committer Section\nRan git commit -m \"msg\" successfully.\nEOF"},"agent_type":"committer","agent_id":"abc"}'
}

# --- Test 1: AGENT_TYPE not committer → allow ---
run_test "non-committer agent → allow" "0" \
    "$(commit_fixture "developer-phoenix-backend")"

# --- Test 2: git status (not git commit) → allow ---
run_test "git status → allow (not a commit)" "0" \
    "$(status_fixture)"

# --- Test 3: codegen-log write narrating "git commit" in heredoc body → allow ---
run_test "codegen-log write narrating git commit → allow" "0" \
    "$(log_write_fixture)"

# --- Test 4b (this pitch): codegen-log TOKEN spelled inside a REAL commit
#     message (not routed through codegen-log — is_codegen_log_write
#     requires the command word itself to resolve to codegen-log) → the
#     verdict check still applies. With a failed verdict, MUST DENY. ---
TMP_TOKEN_SPELLED=$(mktemp -d)
trap 'rm -rf "$TMP_TOKEN_SPELLED"' EXIT
mkdir -p "$TMP_TOKEN_SPELLED/codegen/gate-pending"
printf '{"verdict":"failed"}\n' >"$TMP_TOKEN_SPELLED/codegen/gate-pending/gate-result.json"
run_test "codegen-log token spelled in real commit message, verdict=failed → deny (crossed cell)" "2" \
    "$(commit_fixture "committer" "$TMP_TOKEN_SPELLED" "git commit -m 'ran codegen-log section developer'")" \
    "CLAUDE_PROJECT_DIR=$TMP_TOKEN_SPELLED"

# --- Test 5: gate-result.json absent → deny ---
TMP_ABSENT=$(mktemp -d)
trap 'rm -rf "$TMP_ABSENT"' EXIT
run_test "gate-result.json absent → deny" "2" \
    "$(commit_fixture "committer" "$TMP_ABSENT")" \
    "CLAUDE_PROJECT_DIR=$TMP_ABSENT"

# --- Test 6: gate-result.json verdict=clear → allow ---
TMP_CLEAR=$(mktemp -d)
mkdir -p "$TMP_CLEAR/codegen/gate-pending"
printf '{"verdict":"clear"}\n' >"$TMP_CLEAR/codegen/gate-pending/gate-result.json"
run_test "gate-result.json verdict=clear → allow" "0" \
    "$(commit_fixture "committer" "$TMP_CLEAR")" \
    "CLAUDE_PROJECT_DIR=$TMP_CLEAR"

# --- Test 7: gate-result.json verdict=failed → deny ---
TMP_FAILED=$(mktemp -d)
mkdir -p "$TMP_FAILED/codegen/gate-pending"
printf '{"verdict":"failed"}\n' >"$TMP_FAILED/codegen/gate-pending/gate-result.json"
run_test "gate-result.json verdict=failed → deny" "2" \
    "$(commit_fixture "committer" "$TMP_FAILED")" \
    "CLAUDE_PROJECT_DIR=$TMP_FAILED"

# --- Test 8: gate-result.json verdict=inconclusive → deny ---
TMP_INC=$(mktemp -d)
mkdir -p "$TMP_INC/codegen/gate-pending"
printf '{"verdict":"inconclusive"}\n' >"$TMP_INC/codegen/gate-pending/gate-result.json"
run_test "gate-result.json verdict=inconclusive → deny" "2" \
    "$(commit_fixture "committer" "$TMP_INC")" \
    "CLAUDE_PROJECT_DIR=$TMP_INC"

# --- Test 9: gate-result.json malformed JSON → deny ---
TMP_MALFORMED=$(mktemp -d)
mkdir -p "$TMP_MALFORMED/codegen/gate-pending"
printf '{not valid json' >"$TMP_MALFORMED/codegen/gate-pending/gate-result.json"
run_test "gate-result.json malformed JSON → deny" "2" \
    "$(commit_fixture "committer" "$TMP_MALFORMED")" \
    "CLAUDE_PROJECT_DIR=$TMP_MALFORMED"

# --- Test 10: git commit --amend, verdict=clear → allow ---
run_test "--amend, verdict=clear → allow" "0" \
    "$(commit_fixture "committer" "$TMP_CLEAR" "git commit --amend -m test")" \
    "CLAUDE_PROJECT_DIR=$TMP_CLEAR"

# --- Test 11: git commit --amend, verdict=failed → deny ---
run_test "--amend, verdict=failed → deny" "2" \
    "$(commit_fixture "committer" "$TMP_FAILED" "git commit --amend -m test")" \
    "CLAUDE_PROJECT_DIR=$TMP_FAILED"

# --- Test 12: git -C <dir> commit form, verdict=clear → allow ---
run_test "git -C <dir> commit form, verdict=clear → allow" "0" \
    "$(commit_fixture "committer" "$TMP_CLEAR" "git -C $TMP_CLEAR commit -m test")" \
    "CLAUDE_PROJECT_DIR=$TMP_CLEAR"

# --- Test 13: cd <dir> && git commit form, verdict=clear → allow ---
run_test "cd <dir> && git commit form, verdict=clear → allow" "0" \
    "$(commit_fixture "committer" "$TMP_CLEAR" "cd $TMP_CLEAR && git commit -m test")" \
    "CLAUDE_PROJECT_DIR=$TMP_CLEAR"

# --- Test 14: git commit-graph (not git commit) → allow (word-boundary) ---
commit_graph_fixture() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-graph write"},"agent_type":"committer","agent_id":"abc"}'
}
run_test "git commit-graph → allow (word-boundary fix)" "0" \
    "$(commit_graph_fixture)" \
    "CLAUDE_PROJECT_DIR=$TMP_ABSENT"

# --- Test 15: deny message names the actual verdict value ---
stdout_15=$(printf '%s' "$(commit_fixture "committer" "$TMP_FAILED")" |
    env "CLAUDE_PROJECT_DIR=$TMP_FAILED" bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_15" | grep -q "'failed'"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny message names actual verdict\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny message does not name actual verdict — stdout: %s\n' "$stdout_15"
    fail=$((fail + 1))
fi

# --- Test 16: payload cwd is a subdir of a git repo with clear gate-result
#     at the root → allow (anchor recovers the root) ---
TMP_REPO=$(mktemp -d)
trap 'rm -rf "$TMP_REPO"' EXIT
git -C "$TMP_REPO" init -q
mkdir -p "$TMP_REPO/codegen/gate-pending" "$TMP_REPO/sub/dir"
printf '{"verdict":"clear"}\n' >"$TMP_REPO/codegen/gate-pending/gate-result.json"
run_test "subdir cwd, clear gate-result at repo root → allow" "0" \
    "$(commit_fixture "committer" "$TMP_REPO/sub/dir")" \
    "CLAUDE_PROJECT_DIR=$TMP_REPO/sub/dir"

# --- Test 17: outside any repo, gate-result absent → deny naming both dirs ---
TMP_NOREPO=$(mktemp -d)
trap 'rm -rf "$TMP_NOREPO"' EXIT
stdout_17=$(printf '%s' "$(commit_fixture "committer" "$TMP_NOREPO")" |
    env "CLAUDE_PROJECT_DIR=$TMP_NOREPO" bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_17" | grep -q "is missing at $TMP_NOREPO (resolved from $TMP_NOREPO)"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny names resolved+raw dirs (outside repo)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny does not name resolved+raw dirs — stdout: %s\n' "$stdout_17"
    fail=$((fail + 1))
fi

# --- Test 18: anchored git repo, genuinely absent gate-result → deny naming repo root ---
TMP_REPO_ABSENT=$(mktemp -d)
trap 'rm -rf "$TMP_REPO_ABSENT"' EXIT
git -C "$TMP_REPO_ABSENT" init -q
mkdir -p "$TMP_REPO_ABSENT/sub"
stdout_18=$(printf '%s' "$(commit_fixture "committer" "$TMP_REPO_ABSENT/sub")" |
    env "CLAUDE_PROJECT_DIR=$TMP_REPO_ABSENT/sub" bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$stdout_18" | grep -q "is missing at $TMP_REPO_ABSENT (resolved from $TMP_REPO_ABSENT/sub)"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny names anchored repo root\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny does not name anchored repo root — stdout: %s\n' "$stdout_18"
    fail=$((fail + 1))
fi

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
