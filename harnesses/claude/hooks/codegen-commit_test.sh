#!/bin/bash
# codegen-commit_test.sh — unit tests for the deterministic commit launcher.
#
# Tests:
#   1. --check-subject valid → exit 0, no git state touched
#   2. --check-subject empty → exit 1
#   3. --check-subject multi-line → exit 1
#   4. --check-subject > 72 bytes → exit 1
#   5. --check-subject lowercase first char → exit 1
#   6. --check-subject trailing period → exit 1
#   7. --check-subject Co-Authored-By trailer → exit 1
#   8. --subject with no gate-result.json and no --no-gate → exit 1, no commit
#   9. --subject with gate-result.json verdict=failed → exit 1, no commit
#  10. --subject with gate-result.json verdict=clear → commits, prints COMMITTED
#  11. --subject --no-gate (no gate-result.json at all) → commits
#  12. Empty index (nothing to stage) with --no-gate → exit 1, no commit
#  13. Backward-roll: staged content reverts a prior session commit → exit 1
#  14. Backward-roll with --allow-revert → commits anyway
#  15. Missing --subject/--check-subject → usage exit 2
#  16. Not a git work tree → exit 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../../../codegen-commit"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected [%s] got [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# --- Tests 1-7: --check-subject, no git state required ---

set +e
"$BIN" --check-subject "Prevent duplicate user registrations" >/dev/null 2>&1
assert_eq "valid subject → exit 0" "0" "$?"

"$BIN" --check-subject "" >/dev/null 2>&1
assert_eq "empty subject → exit 1" "1" "$?"

"$BIN" --check-subject "$(printf 'Line one\nLine two')" >/dev/null 2>&1
assert_eq "multi-line subject → exit 1" "1" "$?"

"$BIN" --check-subject "$(printf 'A%.0s' $(seq 1 73))" >/dev/null 2>&1
assert_eq "subject > 72 bytes → exit 1" "1" "$?"

"$BIN" --check-subject "lowercase start" >/dev/null 2>&1
assert_eq "lowercase first char → exit 1" "1" "$?"

"$BIN" --check-subject "Trailing period." >/dev/null 2>&1
assert_eq "trailing period → exit 1" "1" "$?"

"$BIN" --check-subject "Fix bug Co-Authored-By: someone" >/dev/null 2>&1
assert_eq "Co-Authored-By trailer → exit 1" "1" "$?"

# --- Test 15: usage error ---
"$BIN" >/dev/null 2>&1
assert_eq "no args → usage exit 2" "2" "$?"
set -e

# --- Test 16: not a git work tree ---
NONGIT=$(mktemp -d)
set +e
"$BIN" --subject "Do a thing" --cwd "$NONGIT" --no-gate >/dev/null 2>&1
rc=$?
set -e
assert_eq "not a git tree → exit 1" "1" "$rc"
rm -rf "$NONGIT"

# --- Tests 8-14: full commit flow, real git repo ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

(
    cd "$TMP"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "original content" >file.txt
    git add file.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline commit"
)
BASE_SHA=$(git -C "$TMP" rev-parse HEAD)

# Test 8: no gate-result.json, no --no-gate → refuse
echo "change 1" >"$TMP/file.txt"
set +e
"$BIN" --subject "Add change one" --cwd "$TMP" >/dev/null 2>&1
rc=$?
set -e
assert_eq "no gate-result.json, no --no-gate → exit 1" "1" "$rc"
HEAD_AFTER_8=$(git -C "$TMP" rev-parse HEAD)
assert_eq "test 8 did not commit" "$BASE_SHA" "$HEAD_AFTER_8"

# Test 9: gate-result.json verdict=failed → refuse
mkdir -p "$TMP/codegen/gate-pending"
printf '{"verdict":"failed"}' >"$TMP/codegen/gate-pending/gate-result.json"
set +e
"$BIN" --subject "Add change one" --cwd "$TMP" >/dev/null 2>&1
rc=$?
set -e
assert_eq "verdict=failed → exit 1" "1" "$rc"
HEAD_AFTER_9=$(git -C "$TMP" rev-parse HEAD)
assert_eq "test 9 did not commit" "$BASE_SHA" "$HEAD_AFTER_9"

# Test 10: gate-result.json verdict=clear → commit lands
printf '{"verdict":"clear"}' >"$TMP/codegen/gate-pending/gate-result.json"
out=$("$BIN" --subject "Add change one" --cwd "$TMP" 2>&1)
assert_eq "verdict=clear → COMMITTED printed" "1" "$(printf '%s' "$out" | grep -c '^COMMITTED: ')"
HEAD_AFTER_10=$(git -C "$TMP" rev-parse HEAD)
if [ "$HEAD_AFTER_10" != "$BASE_SHA" ]; then
    pass=$((pass + 1))
    [ -n "${VERBOSE:-}" ] && printf 'PASS: test 10 committed (HEAD moved)\n'
else
    fail=$((fail + 1))
    printf 'FAIL: test 10 committed (HEAD moved) — HEAD unchanged\n'
fi

# Test 11: --no-gate with no gate-result.json at all → commits
rm -f "$TMP/codegen/gate-pending/gate-result.json"
echo "change 2" >"$TMP/file.txt"
PRE_11=$(git -C "$TMP" rev-parse HEAD)
out=$("$BIN" --subject "Add change two" --cwd "$TMP" --no-gate 2>&1)
assert_eq "--no-gate with no gate-result.json → COMMITTED printed" "1" "$(printf '%s' "$out" | grep -c '^COMMITTED: ')"
POST_11=$(git -C "$TMP" rev-parse HEAD)
if [ "$PRE_11" != "$POST_11" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    printf 'FAIL: test 11 --no-gate committed — HEAD unchanged\n'
fi

# Test 12: empty index (nothing to stage) → refuse
PRE_12=$(git -C "$TMP" rev-parse HEAD)
set +e
"$BIN" --subject "Add change three" --cwd "$TMP" --no-gate >/dev/null 2>&1
rc=$?
set -e
assert_eq "empty index → exit 1" "1" "$rc"
POST_12=$(git -C "$TMP" rev-parse HEAD)
assert_eq "test 12 did not commit" "$PRE_12" "$POST_12"

# Test 13: backward-roll guard — staged content reverts a prior session commit
CYCLE_BASE=$(git -C "$TMP" rev-parse HEAD)
echo "session commit content" >"$TMP/file.txt"
(cd "$TMP" && git add file.txt && git -c core.hooksPath=/dev/null commit -q -m "session commit")
# Now stage a revert of that session commit (back to "change 2")
git -C "$TMP" show "$CYCLE_BASE:file.txt" >"$TMP/file.txt"
(cd "$TMP" && git add file.txt)
PRE_13=$(git -C "$TMP" rev-parse HEAD)
set +e
CODEGEN_CYCLE_BASE_SHA="$CYCLE_BASE" "$BIN" --subject "Add change four" --cwd "$TMP" --no-gate >/dev/null 2>&1
rc=$?
set -e
assert_eq "backward roll → exit 1" "1" "$rc"
POST_13=$(git -C "$TMP" rev-parse HEAD)
assert_eq "test 13 did not commit" "$PRE_13" "$POST_13"

# Test 14: same backward-roll, --allow-revert → commits anyway
out=$(CODEGEN_CYCLE_BASE_SHA="$CYCLE_BASE" "$BIN" --subject "Add change four" --cwd "$TMP" --no-gate --allow-revert 2>&1)
assert_eq "backward roll + --allow-revert → COMMITTED printed" "1" "$(printf '%s' "$out" | grep -c '^COMMITTED: ')"
POST_14=$(git -C "$TMP" rev-parse HEAD)
if [ "$POST_14" != "$PRE_13" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    printf 'FAIL: test 14 --allow-revert committed — HEAD unchanged\n'
fi

printf '\nResults: %s passed, %s failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
