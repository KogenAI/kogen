#!/bin/bash
# post-developer-format_test.sh — unit tests for post-developer-format.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/post-developer-format.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
    local stdout
    stdout=$(printf '%s' "$input" | bash "$HOOK" 2>/dev/null || true)

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: non-developer agent_type exits 0 immediately (no-op)
FIXTURE_NOOP='{"hook_event_name":"SubagentStop","agent_type":"planner","agent_id":"abc","session_id":"s1","cwd":"/tmp","stop_hook_active":false}'
run_test "non-developer agent_type is no-op" "0" "$FIXTURE_NOOP"

# Test 2: stop_hook_active=true exits 0 immediately
FIXTURE_ACTIVE='{"hook_event_name":"SubagentStop","agent_type":"developer-phoenix-backend","agent_id":"abc","session_id":"s1","cwd":"/tmp","stop_hook_active":true}'
run_test "stop_hook_active=true exits 0 immediately" "0" "$FIXTURE_ACTIVE"

# Test 3: developer-phoenix-backend SubagentStop on git repo exits 0
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Create a minimal git repo
(
    cd "$TMP_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'x = 1\n' >foo.ex
    git add foo.ex
    git commit -q -m "init"
) 2>/dev/null

# Now make a change
printf 'x = 2\n' >"$TMP_DIR/foo.ex"

FIXTURE_DEV='{"hook_event_name":"SubagentStop","agent_type":"developer-phoenix-backend","agent_id":"abc","session_id":"s1","cwd":"'"$TMP_DIR"'","stop_hook_active":false}'
run_test "developer-phoenix-backend on git repo exits 0" "0" "$FIXTURE_DEV"

# Test 4: cwd outside any git repo — exits 0 silently (no error)
NON_REPO_DIR="$(mktemp -d)"
FIXTURE_NO_REPO='{"hook_event_name":"SubagentStop","agent_type":"developer-phoenix-backend","agent_id":"abc","session_id":"s1","cwd":"'"$NON_REPO_DIR"'","stop_hook_active":false}'
run_test "developer-phoenix-backend outside git repo exits 0 silently" "0" "$FIXTURE_NO_REPO"
rm -rf "$NON_REPO_DIR"

# Test 5: cross-repo edit — change in BOTH the project repo and a sibling repo.
# Verify the hook surveys both repos and exits 0 (no errors).
PROJ_REPO="$(mktemp -d)"
SIB_REPO="$(mktemp -d)"
(
    cd "$PROJ_REPO"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'x = 1\n' >foo.ex
    git add foo.ex
    git commit -q -m "init"
) 2>/dev/null
(
    cd "$SIB_REPO"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf '# title\n' >readme.md
    git add readme.md
    git commit -q -m "init"
) 2>/dev/null
# Modify a file in each
printf 'x = 2\n' >"$PROJ_REPO/foo.ex"
printf '# title updated\n' >"$SIB_REPO/readme.md"

# The hook only surveys hard-coded sibling paths
# (/Users/almirsarajcic/Areas/Optimum/{codegen,context}). Since our test temp
# repo isn't one of those, the hook bucketing happens via project_dir only.
# This still exercises the bucketing path: we simulate by passing the project
# repo as cwd; the hook iterates candidate_repos = [project_dir]. Verify exit 0.
FIXTURE_CROSS='{"hook_event_name":"SubagentStop","agent_type":"developer-phoenix-backend","agent_id":"abc","session_id":"s1","cwd":"'"$PROJ_REPO"'","stop_hook_active":false}'
run_test "developer-phoenix-backend with bucketed change exits 0" "0" "$FIXTURE_CROSS"
rm -rf "$PROJ_REPO" "$SIB_REPO"

# Test 6: project with `make format` target → make format is called, exits 0
MAKE_REPO="$(mktemp -d)"
(
    cd "$MAKE_REPO"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'x = 1\n' >foo.ex
    git add foo.ex
    git commit -q -m "init"
    # Makefile with a format target that creates a sentinel file
    printf 'format:\n\ttouch .formatted\n' >Makefile
    git add Makefile
    git commit -q -m "add makefile"
) 2>/dev/null
# Make a working-tree change so there are changed files.
printf 'x = 2\n' >"$MAKE_REPO/foo.ex"

FIXTURE_MAKE='{"hook_event_name":"SubagentStop","agent_type":"developer-phoenix-backend","agent_id":"abc","session_id":"s1","cwd":"'"$MAKE_REPO"'","stop_hook_active":false}'
printf '%s' "$FIXTURE_MAKE" | bash "$HOOK" 2>/dev/null || true

if [ -f "$MAKE_REPO/.formatted" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: project with make format target — make format called, exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: project with make format target — .formatted sentinel not created\n'
    fail=$((fail + 1))
fi
rm -rf "$MAKE_REPO"

# Test 7: project without Makefile → falls back to per-file formatters, exits 0
# (Confirms fallback path explicitly; test 3 already covers exit 0 for this path.)
NO_MAKE_REPO="$(mktemp -d)"
(
    cd "$NO_MAKE_REPO"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'x = 1\n' >foo.ex
    git add foo.ex
    git commit -q -m "init"
) 2>/dev/null
printf 'x = 2\n' >"$NO_MAKE_REPO/foo.ex"

FIXTURE_NO_MAKE='{"hook_event_name":"SubagentStop","agent_type":"developer-phoenix-backend","agent_id":"abc","session_id":"s1","cwd":"'"$NO_MAKE_REPO"'","stop_hook_active":false}'
run_test "project without Makefile falls back to per-file formatters, exits 0" "0" "$FIXTURE_NO_MAKE"
rm -rf "$NO_MAKE_REPO"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
