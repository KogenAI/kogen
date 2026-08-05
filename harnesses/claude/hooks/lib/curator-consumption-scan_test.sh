#!/usr/bin/env bash
# curator-consumption-scan_test.sh — unit tests for curator-consumption-scan.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/curator-consumption-scan.sh"

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
    git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf "$dir\n"
}

# --- Test 1: zero upstream ev:learned events -> exit 0 (nothing to consume) ---
T1=$(new_repo)
LOG1="$T1/cycle.jsonl"
{
    printf '{"ev":"role","role":"developer-phoenix-backend","body":"did stuff"}\n'
    printf '{"ev":"no_learning","role":"developer-phoenix-backend","text":"nothing durable"}\n'
} >"$LOG1"
out=$(bash "$SCAN" "$T1" "$LOG1")
rc=$?
assert_exit "zero upstream learnings -> exit 0" "0" "$rc"
assert_eq "zero upstream learnings -> empty stdout" "" "$out"
rm -rf "$T1"

# --- Test 2: learnings captured + a context/*.md edit -> exit 0 (routed) ---
T2=$(new_repo)
mkdir -p "$T2/context"
printf '# context doc\n' >"$T2/context/foo.md"
LOG2="$T2/cycle.jsonl"
printf '{"ev":"learned","role":"developer-phoenix-backend","text":"[shared] something real learned here"}\n' >"$LOG2"
out=$(bash "$SCAN" "$T2" "$LOG2")
rc=$?
assert_exit "learnings + context/*.md edit -> exit 0" "0" "$rc"
rm -rf "$T2"

# --- Test 3: learnings captured + a shared/rules/**.md edit -> exit 0 (routed) ---
# THE SYMLINK-TRAP REGRESSION: git NEVER reports a path spelled codegen/rules/**
# (codegen/rules is a symlink into shared/rules/, and /codegen/ is gitignored,
# so git check-ignore on a codegen/rules/** path returns "fatal: pathspec is
# beyond a symbolic link"). A filter written against the codegen/rules/**
# spelling would match nothing here and fail this test (false exit 1).
T3=$(new_repo)
mkdir -p "$T3/shared/rules/roles"
printf '# curator rule\n' >"$T3/shared/rules/roles/context-curator.md"
LOG3="$T3/cycle.jsonl"
printf '{"ev":"learned","role":"developer-phoenix-backend","text":"[shared] a real learning"}\n' >"$LOG3"
out=$(bash "$SCAN" "$T3" "$LOG3")
rc=$?
assert_exit "learnings + shared/rules/**.md edit -> exit 0 (symlink-trap regression)" "0" "$rc"
rm -rf "$T3"

# --- Test 4: learnings captured + no edit + no curator learned -> exit 1, names counts ---
T4=$(new_repo)
LOG4="$T4/cycle.jsonl"
{
    printf '{"ev":"learned","role":"developer-phoenix-backend","text":"[shared] learning one"}\n'
    printf '{"ev":"learned","role":"developer-phoenix-backend","text":"[local] learning two"}\n'
} >"$LOG4"
out=$(bash "$SCAN" "$T4" "$LOG4")
rc=$?
assert_exit "learnings, nothing routed, no drop record -> exit 1" "1" "$rc"
case "$out" in
*"captured"*"2"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: exit 1 message should name captured count\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
case "$out" in
*"routed"*"0"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: exit 1 message should name routed count\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
rm -rf "$T4"

# --- Test 5: learnings captured + curator ev:learned per drop, no edit -> exit 0 ---
T5=$(new_repo)
LOG5="$T5/cycle.jsonl"
{
    printf '{"ev":"learned","role":"developer-phoenix-backend","text":"[shared] learning one"}\n'
    printf '{"ev":"learned","role":"context-curator","text":"dropped: learning one was too trivial to route, no durable doc change needed"}\n'
} >"$LOG5"
out=$(bash "$SCAN" "$T5" "$LOG5")
rc=$?
assert_exit "learnings + curator drop record -> exit 0" "0" "$rc"
rm -rf "$T5"

# --- Test 6: missing/nonexistent cycle log -> exit 1 (cannot prove consumption) ---
T6=$(new_repo)
out=$(bash "$SCAN" "$T6" "$T6/does-not-exist.jsonl")
rc=$?
assert_exit "missing cycle log -> exit 1" "1" "$rc"
rm -rf "$T6"

# --- Test 7: no args -> exit 2 (usage error) ---
out=$(bash "$SCAN" 2>&1)
rc=$?
assert_exit "no args -> exit 2" "2" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
