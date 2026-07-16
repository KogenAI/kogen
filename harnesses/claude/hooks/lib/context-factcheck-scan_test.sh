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

# --- Test 15: Elixir source-root fallback (lib/) → resolves, exit 0 ---
T15=$(new_repo)
mkdir -p "$T15/lib/widgetapp"
printf 'code\n' >"$T15/lib/widgetapp/billing.ex"
printf 'See `widgetapp/billing.ex` for details.\n' >"$T15/CLAUDE.md"
out=$(bash "$SCAN" "$T15")
rc=$?
assert_exit "Elixir source-root (lib/) fallback → exit 0" "0" "$rc"
rm -rf "$T15"

# --- Test 16: Elixir source-root fallback (test/) → resolves, exit 0 ---
T16=$(new_repo)
mkdir -p "$T16/test/widgetapp"
printf 'code\n' >"$T16/test/widgetapp/billing_test.exs"
printf 'See `widgetapp/billing_test.exs` for details.\n' >"$T16/CLAUDE.md"
out=$(bash "$SCAN" "$T16")
rc=$?
assert_exit "Elixir source-root (test/) fallback → exit 0" "0" "$rc"
rm -rf "$T16"

# --- Test 17: Elixir path missing everywhere (literal, lib/, test/) → exit 1 ---
T17=$(new_repo)
printf 'See `widgetapp/nope.ex` for details.\n' >"$T17/CLAUDE.md"
out=$(bash "$SCAN" "$T17")
rc=$?
assert_exit "genuinely-dead .ex path → exit 1" "1" "$rc"
case "$out" in
*"widgetapp/nope.ex"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: genuinely-dead .ex path → message should reference path\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
rm -rf "$T17"

# --- Test 18: non-.ex/.exs path still fails literal-only (no source-root fallback) ---
T18=$(new_repo)
mkdir -p "$T18/lib/widgetapp"
printf 'x\n' >"$T18/lib/widgetapp/notes.md"
printf 'See `widgetapp/notes.md` for details.\n' >"$T18/CLAUDE.md"
out=$(bash "$SCAN" "$T18")
rc=$?
assert_exit "non-.ex/.exs path → no source-root fallback → exit 1" "1" "$rc"
rm -rf "$T18"

# --- Test 19: diff-scope explicit doc args → scans ONLY named docs ---
T19=$(new_repo)
printf 'See `widgetapp/nope.ex` for details.\n' >"$T19/CLAUDE.md"
printf 'Nothing wrong here.\n' >"$T19/AGENTS.md"
out=$(bash "$SCAN" "$T19" "AGENTS.md")
rc=$?
assert_exit "diff-scope: unscanned doc's violation ignored → exit 0" "0" "$rc"
rm -rf "$T19"

# --- Test 20: diff-scope explicit doc args → still catches violation in scanned doc ---
T20=$(new_repo)
printf 'See `widgetapp/nope.ex` for details.\n' >"$T20/CLAUDE.md"
printf 'Nothing wrong here.\n' >"$T20/AGENTS.md"
out=$(bash "$SCAN" "$T20" "CLAUDE.md")
rc=$?
assert_exit "diff-scope: violation in scanned doc still caught → exit 1" "1" "$rc"
rm -rf "$T20"

# --- Test 21: identifier corruption (word-internal '*') → exit 1, token in message ---
T21=$(new_repo)
printf 'Call `register*route_or_live` to add a route.\n' >"$T21/CLAUDE.md"
out=$(bash "$SCAN" "$T21")
rc=$?
assert_exit "identifier corruption → exit 1" "1" "$rc"
case "$out" in
*"register*route"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: identifier corruption → message should reference token\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
rm -rf "$T21"

# --- Test 22: FP-GUARD — legit '*' uses (globs, regex, bold) → exit 0, empty stdout ---
T22=$(new_repo)
cat >"$T22/CLAUDE.md" <<'DOC'
See context/*.md for domain docs.
Env vars follow the OCG_* convention.
Hooks named no-*.sh live under harnesses/claude/hooks/.
Regex `.*` matches anything.
This is **bold** text and this is *italic* text.
DOC
out=$(bash "$SCAN" "$T22")
rc=$?
assert_exit "FP-guard: legit '*' uses → exit 0" "0" "$rc"
assert_eq "FP-guard: legit '*' uses → empty stdout" "" "$out"
rm -rf "$T22"

# --- Test 23: mixed doc — one corrupt line + clean lines → exit 1, names only corrupt line ---
T23=$(new_repo)
cat >"$T23/CLAUDE.md" <<'DOC'
# Heading

This line is fine.
See context/*.md for domain docs.
Call `fn foo*bar end` — corrupted from foo_bar.
Another fine line.
DOC
out=$(bash "$SCAN" "$T23")
rc=$?
assert_exit "mixed doc: corrupt + clean → exit 1" "1" "$rc"
case "$out" in
*":5 "*"foo*bar"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: mixed doc → message should name line 5 and token foo*bar\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
# Ensure only ONE violation line printed (not clean lines).
out_lines=$(printf '%s\n' "$out" | grep -c . || true)
assert_eq "mixed doc: exactly one violation line" "1" "$out_lines"
rm -rf "$T23"

# --- Test 24: FACTCHECK_DOC_ROOT unset → back-compat, doc read from repo_root ---
T24=$(new_repo)
mkdir -p "$T24/lib/foo"
printf 'code\n' >"$T24/lib/foo/bar.ex"
printf 'See `lib/foo/bar.ex` for details.\n' >"$T24/CLAUDE.md"
out=$(bash "$SCAN" "$T24")
rc=$?
assert_exit "FACTCHECK_DOC_ROOT unset → back-compat exit 0" "0" "$rc"
rm -rf "$T24"

# --- Test 25: FACTCHECK_DOC_ROOT set to a projection mirror → doc content
# read from the mirror, but named-path claims resolve against the REAL
# repo_root (proves the split: mirror holds only the doc, not the source tree) ---
T25=$(new_repo)
mkdir -p "$T25/lib/foo"
printf 'code\n' >"$T25/lib/foo/bar.ex"
mirror25=$(mktemp -d)
mkdir -p "$mirror25/context"
printf 'See `lib/foo/bar.ex` for details.\n' >"$mirror25/context/projected.md"
out=$(FACTCHECK_DOC_ROOT="$mirror25" bash "$SCAN" "$T25" "context/projected.md")
rc=$?
assert_exit "FACTCHECK_DOC_ROOT mirror + real repo_root → valid path resolves, exit 0" "0" "$rc"
rm -rf "$T25" "$mirror25"

# --- Test 26: FACTCHECK_DOC_ROOT set, real repo_root missing the claimed path
# → genuine violation still caught (proves resolution is NOT against the
# mirror, which has no lib/ at all) ---
T26=$(new_repo)
mirror26=$(mktemp -d)
mkdir -p "$mirror26/context"
printf 'See `lib/does_not_exist.ex` for details.\n' >"$mirror26/context/projected.md"
out=$(FACTCHECK_DOC_ROOT="$mirror26" bash "$SCAN" "$T26" "context/projected.md")
rc=$?
assert_exit "FACTCHECK_DOC_ROOT mirror + real repo_root → stale path still caught, exit 1" "1" "$rc"
case "$out" in
*"lib/does_not_exist.ex"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: FACTCHECK_DOC_ROOT stale-path → message should reference path\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
rm -rf "$T26" "$mirror26"

# --- Test 27: placeholder-segment path (`<app>/context/core.md`) → skipped, exit 0 ---
# Locks the accidental-turned-intentional escape: a doc describing a path
# inside a provisioned/downstream app (not this repo) uses a placeholder
# segment so claim class 1 never asserts it against repo_root.
T27=$(new_repo)
printf 'See `<app>/context/core.md` for the provisioned stub.\n' >"$T27/CLAUDE.md"
out=$(bash "$SCAN" "$T27")
rc=$?
assert_exit "placeholder-segment path → exit 0" "0" "$rc"
assert_eq "placeholder-segment path → empty stdout" "" "$out"
rm -rf "$T27"

# --- Test 28: bare (non-placeholder) missing path → violation message names
# the placeholder-segment escape hatch ---
T28=$(new_repo)
printf 'See `context/core.md` for details.\n' >"$T28/CLAUDE.md"
out=$(bash "$SCAN" "$T28")
rc=$?
assert_exit "bare missing path → exit 1" "1" "$rc"
case "$out" in
*"placeholder segment"*"<app>/context/core.md"*) pass=$((pass + 1)) ;;
*)
    printf 'FAIL: bare missing path → message should teach the placeholder-segment escape\n  actual: %s\n' "$out"
    fail=$((fail + 1))
    ;;
esac
rm -rf "$T28"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
