#!/bin/bash
# context-file-size-gate_test.sh — unit tests for context-file-size-gate.sh
#
# Tests:
#   1: staged ADD context/big.md at 50000 bytes → DENY
#   2: staged MODIFY context/existing.md grown to 50000 bytes → DENY
#   3: staged ADD context/ok.md at 100 bytes → ALLOW
#   4: staged ADD context/exact.md at exactly 40960 bytes → ALLOW (boundary: not > CAP)
#   5: staged ADD context/over.md at 40961 bytes → DENY (boundary: one over)
#   6: staged DELETE of over-cap context/gone.md (status D) → ALLOW (D not matched)
#   7: staged ADD lib/foo.ex at 99999 bytes → ALLOW (not context/*.md)
#   8: staged ADD context/sub/nested.md (subdir) at 99999 bytes → ALLOW (subdir excluded)
#   9: git status (non-commit) with over-cap staged → ALLOW (command anchor)
#  10: echo "git commit" substring with over-cap staged → ALLOW (anchor)
#  11: Read tool with git commit payload + over-cap staged → ALLOW (tool guard)
#  12: git commit -m "x" in non-git CWD → ALLOW (graceful)
#  13: git commit --amend with over-cap staged ADD → DENY (--amend matches git commit\b)
#  14: two staged adds: one 50000 (over) + one 100 (under) → DENY naming only over-cap file
#  15: committer subagent (agent_type=committer) with over-cap staged ADD → DENY
#  16: deny message contains exact byte count and "40960-byte (40k) cap" substring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/context-file-size-gate.sh"

pass=0
fail=0

# Cleanup fixtures at exit.
FIXTURES=()
cleanup() {
    for d in "${FIXTURES[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# make_fixture <n> — create /tmp/context-size-test-<n>/ with git init + identity.
# Prints the fixture path.
make_fixture() {
    local n="$1"
    local dir="/tmp/context-size-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context" "$dir/lib"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@t"
    git -C "$dir" config user.name "t"
    printf 'init\n' >"$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "init"
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

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

# ---------------------------------------------------------------------------
# Test 1: staged ADD context/big.md at 50000 bytes → DENY
# ---------------------------------------------------------------------------
dir1=$(make_fixture 1)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir1/context/big.md"
git -C "$dir1" add "context/big.md"

run_test "staged ADD context/big.md at 50000 bytes → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add big\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir1\"}"

# ---------------------------------------------------------------------------
# Test 2: staged MODIFY context/existing.md grown to 50000 bytes → DENY
# ---------------------------------------------------------------------------
dir2=$(make_fixture 2)
printf 'small\n' >"$dir2/context/existing.md"
git -C "$dir2" add "context/existing.md"
git -C "$dir2" commit -q -m "add small"
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir2/context/existing.md"
git -C "$dir2" add "context/existing.md"

run_test "staged MODIFY context/existing.md grown to 50000 bytes → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"grow\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir2\"}"

# ---------------------------------------------------------------------------
# Test 3: staged ADD context/ok.md at 100 bytes → ALLOW
# ---------------------------------------------------------------------------
dir3=$(make_fixture 3)
head -c 100 /dev/zero | tr '\0' 'x' >"$dir3/context/ok.md"
git -C "$dir3" add "context/ok.md"

run_test "staged ADD context/ok.md at 100 bytes → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add ok\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir3\"}"

# ---------------------------------------------------------------------------
# Test 4: staged ADD context/exact.md at exactly 40960 bytes → ALLOW (not > CAP)
# ---------------------------------------------------------------------------
dir4=$(make_fixture 4)
head -c 40960 /dev/zero | tr '\0' 'x' >"$dir4/context/exact.md"
git -C "$dir4" add "context/exact.md"

run_test "staged ADD context/exact.md at exactly 40960 bytes → ALLOW (boundary)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add exact\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir4\"}"

# ---------------------------------------------------------------------------
# Test 5: staged ADD context/over.md at 40961 bytes → DENY (one over boundary)
# ---------------------------------------------------------------------------
dir5=$(make_fixture 5)
head -c 40961 /dev/zero | tr '\0' 'x' >"$dir5/context/over.md"
git -C "$dir5" add "context/over.md"

run_test "staged ADD context/over.md at 40961 bytes → DENY (one over boundary)" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add over\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir5\"}"

# ---------------------------------------------------------------------------
# Test 6: staged DELETE of over-cap context/gone.md (status D) → ALLOW
# D lines not matched by ^[AM] filter
# ---------------------------------------------------------------------------
dir6=$(make_fixture 6)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir6/context/gone.md"
git -C "$dir6" add "context/gone.md"
git -C "$dir6" commit -q -m "add gone"
git -C "$dir6" rm -q "context/gone.md"

run_test "staged DELETE of over-cap context/gone.md → ALLOW (D not matched)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"remove gone\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir6\"}"

# ---------------------------------------------------------------------------
# Test 7: staged ADD lib/foo.ex at 99999 bytes → ALLOW (not context/*.md)
# ---------------------------------------------------------------------------
dir7=$(make_fixture 7)
head -c 99999 /dev/zero | tr '\0' 'x' >"$dir7/lib/foo.ex"
git -C "$dir7" add "lib/foo.ex"

run_test "staged ADD lib/foo.ex at 99999 bytes → ALLOW (not context/*.md)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add foo\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir7\"}"

# ---------------------------------------------------------------------------
# Test 8: staged ADD context/sub/nested.md (subdir) at 99999 bytes → ALLOW
# regex context/[^/]+\.md$ excludes subdirs
# ---------------------------------------------------------------------------
dir8=$(make_fixture 8)
mkdir -p "$dir8/context/sub"
head -c 99999 /dev/zero | tr '\0' 'x' >"$dir8/context/sub/nested.md"
git -C "$dir8" add "context/sub/nested.md"

run_test "staged ADD context/sub/nested.md (subdir) at 99999 bytes → ALLOW (subdir excluded)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add nested\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir8\"}"

# ---------------------------------------------------------------------------
# Test 9: git status (non-commit) with over-cap staged → ALLOW (command anchor)
# ---------------------------------------------------------------------------
dir9=$(make_fixture 9)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir9/context/big.md"
git -C "$dir9" add "context/big.md"

run_test "git status (non-commit) with over-cap staged → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir9\"}"

# ---------------------------------------------------------------------------
# Test 10: echo "git commit" substring with over-cap staged → ALLOW (anchor)
# ---------------------------------------------------------------------------
dir10=$(make_fixture 10)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir10/context/big.md"
git -C "$dir10" add "context/big.md"

run_test "echo \"git commit\" substring with over-cap staged → ALLOW (anchor)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\"git commit\\\"\"},\"agent_type\":\"developer-phoenix-backend\",\"agent_id\":\"a\",\"cwd\":\"$dir10\"}"

# ---------------------------------------------------------------------------
# Test 11: Read tool with git commit payload + over-cap staged → ALLOW (tool guard)
# ---------------------------------------------------------------------------
dir11=$(make_fixture 11)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir11/context/big.md"
git -C "$dir11" add "context/big.md"

run_test "Read tool with git commit payload + over-cap staged → ALLOW (tool guard)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir11\"}"

# ---------------------------------------------------------------------------
# Test 12: git commit -m "x" in non-git CWD → ALLOW (graceful)
# ---------------------------------------------------------------------------
dir12="/tmp/context-size-test-12-nogit"
rm -rf "$dir12"
mkdir -p "$dir12"
FIXTURES+=("$dir12")

run_test "non-git CWD → ALLOW (graceful)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir12\"}"

# ---------------------------------------------------------------------------
# Test 13: git commit --amend with over-cap staged ADD → DENY
# --amend still matches git commit\b
# ---------------------------------------------------------------------------
dir13=$(make_fixture 13)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir13/context/big.md"
git -C "$dir13" add "context/big.md"

run_test "git commit --amend with over-cap staged ADD → DENY (--amend matches)" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir13\"}"

# ---------------------------------------------------------------------------
# Test 14: two staged adds: one 50000 (over) + one 100 (under) → DENY
# message names ONLY the over-cap file, NOT the under-cap file
# ---------------------------------------------------------------------------
dir14=$(make_fixture 14)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir14/context/over.md"
head -c 100 /dev/zero | tr '\0' 'x' >"$dir14/context/small.md"
git -C "$dir14" add "context/over.md" "context/small.md"

stdout14=$(printf '%s' \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add both\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir14\"}" |
    bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout14" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    printf '%s' "$stdout14" | grep -q "context/over.md" &&
    ! printf '%s' "$stdout14" | grep -q "context/small.md"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: two staged adds: DENY names over-cap only\n'
    pass=$((pass + 1))
else
    printf 'FAIL: two staged adds — expected DENY naming over.md only\n  stdout: %s\n' "$stdout14"
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# Test 15: committer subagent (agent_type=committer) with over-cap staged ADD → DENY
# Proves no is_outer_session() gating — committer subagents must be blocked too
# ---------------------------------------------------------------------------
dir15=$(make_fixture 15)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir15/context/big.md"
git -C "$dir15" add "context/big.md"

run_test "committer subagent with over-cap staged ADD → DENY (no is_outer_session gating)" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"commit\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir15\"}"

# ---------------------------------------------------------------------------
# Test 16: deny message contains exact byte count and "40960-byte (40k) cap" substring
# ---------------------------------------------------------------------------
dir16=$(make_fixture 16)
head -c 50000 /dev/zero | tr '\0' 'x' >"$dir16/context/big.md"
git -C "$dir16" add "context/big.md"

stdout16=$(printf '%s' \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir16\"}" |
    bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout16" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    printf '%s' "$stdout16" | grep -q "50000" &&
    printf '%s' "$stdout16" | grep -q "40960-byte (40k) cap"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny message contains exact byte count and cap substring\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny message missing byte count or cap substring\n  stdout: %s\n' "$stdout16"
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
