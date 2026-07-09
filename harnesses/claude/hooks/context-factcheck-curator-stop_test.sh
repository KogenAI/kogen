#!/bin/bash
# context-factcheck-curator-stop_test.sh — unit tests for
# context-factcheck-curator-stop.sh (SubagentStop hook for context-curator)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GUARD_OVERRIDE:-$SCRIPT_DIR/context-factcheck-curator-stop.sh}"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local test_dir="$4"

    local stdout
    stdout=$(cd "$test_dir" && printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        outcome="block"
    else
        outcome="allow"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

(
    cd "$TMP_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    printf '# platform marker\n' >PROJECT_CONTEXT.md
    mkdir -p context
    printf '# Foo\n\nSee `context/bar.md` for detail.\n' >context/foo.md
    printf '# Bar\n' >context/bar.md
    git add -A
    git commit -q -m "init"
)

payload() {
    local agent_type="$1"
    local stop_active="$2"
    printf '{"hook_event_name":"SubagentStop","agent_type":"%s","cwd":"%s","session_id":"s1","stop_hook_active":%s}' \
        "$agent_type" "$TMP_DIR" "$stop_active"
}

# Test 1: clean working-tree docs — allow
FIXTURE_CLEAN=$(payload "context-curator" "false")
run_test "clean working-tree docs allows" "allow" "$FIXTURE_CLEAN" "$TMP_DIR"

# Test 2: non-context-curator agent — not gated
FIXTURE_OTHER=$(payload "committer" "false")
run_test "non-context-curator agent is not gated" "allow" "$FIXTURE_OTHER" "$TMP_DIR"

# Test 3: STOP_HOOK_ACTIVE=true — loop guard allows
FIXTURE_LOOP=$(payload "context-curator" "true")
run_test "stop_hook_active loop guard allows" "allow" "$FIXTURE_LOOP" "$TMP_DIR"

# Test 4: working-tree doc has backtick'd nonexistent path — block
(
    cd "$TMP_DIR"
    printf '# Foo\n\nSee `context/nonexistent.md` for detail.\n' >context/foo.md
)
FIXTURE_BAD_PATH=$(payload "context-curator" "false")
run_test "nonexistent path claim blocks" "block" "$FIXTURE_BAD_PATH" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/foo.md)

# Test 5: count-anchor mismatch — block
(
    cd "$TMP_DIR"
    printf 'file1\nfile2\n' >context/two.txt
    printf '# Foo\n\n<!-- count: ls context/*.txt | wc -l -->99\n' >context/foo.md
)
FIXTURE_COUNT_MISMATCH=$(payload "context-curator" "false")
run_test "count anchor mismatch blocks" "block" "$FIXTURE_COUNT_MISMATCH" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/foo.md && rm -f context/two.txt)

# Test 6: count-anchor match — allow
(
    cd "$TMP_DIR"
    printf 'file1\nfile2\n' >context/two.txt
    printf '# Foo\n\n<!-- count: ls context/*.txt | wc -l -->1\n' >context/foo.md
)
FIXTURE_COUNT_MATCH=$(payload "context-curator" "false")
run_test "count anchor match allows" "allow" "$FIXTURE_COUNT_MATCH" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/foo.md && rm -f context/two.txt)

# Test 7: is_codegen_log_write bypass (COMMAND unset on SubagentStop; treated
# as not a codegen-log write, so this is functionally the same as clean-docs;
# assert allow to confirm no crash on the bypass check itself)
FIXTURE_BYPASS=$(payload "context-curator" "false")
run_test "is_codegen_log_write bypass check does not crash" "allow" "$FIXTURE_BYPASS" "$TMP_DIR"

# Test 8: disallowed probe verb — block
(
    cd "$TMP_DIR"
    printf '# Foo\n\n<!-- count: rm -rf / -->1\n' >context/foo.md
)
FIXTURE_BAD_VERB=$(payload "context-curator" "false")
run_test "disallowed probe verb blocks" "block" "$FIXTURE_BAD_VERB" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/foo.md)

# Test 9: injection token in probe — block
(
    cd "$TMP_DIR"
    printf '# Foo\n\n<!-- count: ls $(whoami) -->1\n' >context/foo.md
)
FIXTURE_INJECTION=$(payload "context-curator" "false")
run_test "injection token in probe blocks" "block" "$FIXTURE_INJECTION" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/foo.md)

# Test 10: probe infra fault (non-integer output) — fail-open, allow
(
    cd "$TMP_DIR"
    printf '# Foo\n\n<!-- count: grep nonexistent_pattern_xyz context/bar.md -->1\n' >context/foo.md
)
FIXTURE_INFRA_FAULT=$(payload "context-curator" "false")
run_test "probe infra fault fails open (allow)" "allow" "$FIXTURE_INFRA_FAULT" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/foo.md)

# Test 11: CROSS-FILE case — doc references a path; that path is deleted
# (unstaged rm) from the tree by a change to a DIFFERENT file's edit. This is
# the whole-tree completeness property a per-edit gate structurally cannot
# see — the referencing doc (context/foo.md) is untouched, only the
# referenced file (context/bar.md) is removed.
(
    cd "$TMP_DIR"
    rm -f context/bar.md
)
FIXTURE_CROSS_FILE=$(payload "context-curator" "false")
run_test "cross-file deletion of referenced path blocks (whole-tree completeness)" "block" "$FIXTURE_CROSS_FILE" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- context/bar.md)

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
