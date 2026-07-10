#!/usr/bin/env bash
# context-factcheck-scan_test.sh — unit tests for context-factcheck-scan.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/context-factcheck-scan.sh"

pass=0
fail=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

assert_exit() {
    local name="$1" expected="$2" actual="$3"
    assert_eq "$name" "$expected" "$actual"
}

new_repo() {
    local dir
    dir=$(mktemp -d)
    dir=$(cd "$dir" && pwd -P)
    git -C "$dir" init -q
    printf '# ctx\n' >"$dir/PROJECT_CONTEXT.md"
    mkdir -p "$dir/context"
    printf "$dir\n"
}

# --- Test 1: clean docs → exit 0, empty stdout ---
T1=$(new_repo)
printf '# CLAUDE\nNothing to see here.\n' >"$T1/CLAUDE.md"
out=$(bash "$SCAN" "$T1")
rc=$?
assert_exit "clean docs → exit 0" "0" "$rc"
assert_eq "clean docs → empty stdout" "" "$out"
rm -rf "$T1"

# --- Test 2: nonexistent named path → exit 1, path in message ---
T2=$(new_repo)
printf 'See `lib/mix/tasks/new_task.ex` for details.\n' >"$T2/CLAUDE.md"
out=$(bash "$SCAN" "$T2")
rc=$?
assert_exit "nonexistent path → exit 1" "1" "$rc"
case "$out" in
*"lib/mix/tasks/new_task.ex"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: nonexistent path → message should reference path\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
rm -rf "$T2"

# --- Test 3: count-anchor mismatch → exit 1 ---
T3=$(new_repo)
printf 'files: <!-- count: ls | wc -l -->999\n' >"$T3/CLAUDE.md"
out=$(bash "$SCAN" "$T3")
rc=$?
assert_exit "count-anchor mismatch → exit 1" "1" "$rc"
rm -rf "$T3"

# --- Test 4: malformed NNN → exit 1 ---
T4=$(new_repo)
printf 'files: <!-- count: ls -->notanumber\n' >"$T4/CLAUDE.md"
out=$(bash "$SCAN" "$T4")
rc=$?
assert_exit "malformed NNN → exit 1" "1" "$rc"
rm -rf "$T4"

# --- Test 5: disallowed verb → exit 1 ---
T5=$(new_repo)
printf 'files: <!-- count: rm -rf / -->0\n' >"$T5/CLAUDE.md"
out=$(bash "$SCAN" "$T5")
rc=$?
assert_exit "disallowed verb → exit 1" "1" "$rc"
rm -rf "$T5"

# --- Test 6: injection token → exit 1 ---
T6=$(new_repo)
printf 'files: <!-- count: ls; rm -rf / -->0\n' >"$T6/CLAUDE.md"
out=$(bash "$SCAN" "$T6")
rc=$?
assert_exit "injection token → exit 1" "1" "$rc"
rm -rf "$T6"

# --- Test 7: probe-infra fault → exit 0 (fail-open) ---
T7=$(new_repo)
printf 'files: <!-- count: grep nonexistent-pattern-xyz nonexistent-file -->0\n' >"$T7/CLAUDE.md"
out=$(bash "$SCAN" "$T7")
rc=$?
assert_exit "probe-infra fault → exit 0 fail-open" "0" "$rc"
rm -rf "$T7"

# --- Test 8: missing docs entirely → exit 0 ---
T8=$(new_repo)
out=$(bash "$SCAN" "$T8")
rc=$?
assert_exit "missing docs → exit 0" "0" "$rc"
rm -rf "$T8"

# --- Test 9: non-git repo_root → exit 0 ---
T9=$(mktemp -d)
T9=$(cd "$T9" && pwd -P)
out=$(bash "$SCAN" "$T9")
rc=$?
assert_exit "non-git repo_root → exit 0" "0" "$rc"
rm -rf "$T9"

# --- Test 10: absent repo_root arg → exit 0 ---
out=$(bash "$SCAN")
rc=$?
assert_exit "absent repo_root arg → exit 0" "0" "$rc"

# --- Test 11: valid named path (exists) → exit 0 ---
T11=$(new_repo)
mkdir -p "$T11/lib/foo"
printf 'code\n' >"$T11/lib/foo/bar.ex"
printf 'See `lib/foo/bar.ex` for details.\n' >"$T11/CLAUDE.md"
out=$(bash "$SCAN" "$T11")
rc=$?
assert_exit "valid named path → exit 0" "0" "$rc"
rm -rf "$T11"

# --- Test 12: valid count anchor (matches) → exit 0 ---
T12=$(new_repo)
mkdir -p "$T12/context"
printf 'a\n' >"$T12/context/a.md"
printf 'b\n' >"$T12/context/b.md"
count=$(find "$T12/context" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')
printf 'files: <!-- count: ls context | grep -c .md -->%s\n' "$count" >"$T12/CLAUDE.md"
out=$(bash "$SCAN" "$T12")
rc=$?
assert_exit "valid count anchor → exit 0" "0" "$rc"
rm -rf "$T12"

# --- Test 13: userapp layout (codegen/PROJECT_CONTEXT.md, no top-level) → scanned ---
T13=$(mktemp -d)
T13=$(cd "$T13" && pwd -P)
git -C "$T13" init -q
mkdir -p "$T13/codegen"
printf '# ctx\n' >"$T13/codegen/PROJECT_CONTEXT.md"
printf 'See `lib/mix/tasks/new_task.ex` for details.\n' >"$T13/CLAUDE.md"
out=$(bash "$SCAN" "$T13")
rc=$?
assert_exit "userapp layout → violation still caught" "1" "$rc"
rm -rf "$T13"

# --- Test 14: repo without PROJECT_CONTEXT.md at all → exit 0 (no layout) ---
T14=$(mktemp -d)
T14=$(cd "$T14" && pwd -P)
git -C "$T14" init -q
printf 'See `lib/mix/tasks/new_task.ex` for details.\n' >"$T14/CLAUDE.md"
out=$(bash "$SCAN" "$T14")
rc=$?
assert_exit "no PROJECT_CONTEXT.md → exit 0 (no layout detected)" "0" "$rc"
rm -rf "$T14"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
