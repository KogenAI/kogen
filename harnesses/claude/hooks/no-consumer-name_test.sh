#!/usr/bin/env bash
# no-consumer-name_test.sh — contract test: no consumer/project name tokens in source tree

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0

# Temp files to clean up
TMPFILES=()
TMPDIRS=()
cleanup() {
    if [ ${#TMPFILES[@]} -gt 0 ]; then
        rm -f "${TMPFILES[@]}"
    fi
    if [ ${#TMPDIRS[@]} -gt 0 ]; then
        rm -rf "${TMPDIRS[@]}"
    fi
}
trap cleanup EXIT

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_nonempty() {
    local desc="$1"
    local actual="$2"
    if [ -n "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s (expected non-empty, got empty)\n' "$desc"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local desc="$1"
    local actual="$2"
    if [ -z "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s (expected empty, got: %s)\n' "$desc" "$actual"
        fail=$((fail + 1))
    fi
}

# scan(): grep for 'combobulate' (case-insensitive) across the codegen source tree,
# excluding dirs that legitimately hold historical/user data, generated runtime files,
# and this test script itself (which uses the token as a search pattern/test fixture).
scan() {
    grep -rIl -i 'combobulate' "$CODEGEN_ROOT" \
        --exclude-dir=node_modules \
        --exclude-dir=.git \
        --exclude-dir=benchmarks \
        --exclude-dir=logging \
        --exclude-dir=dist \
        --exclude-dir=coverage \
        --exclude-dir=tmp \
        --exclude-dir=recipes-combobulate \
        --exclude-dir=.claude \
        --exclude-dir=runs \
        2>/dev/null |
        grep -v 'test_harness/deps\|test_harness/_build\|codegen/pitches' |
        grep -v 'no-consumer-name_test\.sh' |
        grep -v '\-system-prompt\.txt$' |
        grep -v 'scaffold_test\.sh$' ||
        true
}

# scan_dir(): grep a specific directory path
scan_dir() {
    local dir="$1"
    grep -rIl -i 'combobulate' "$dir" \
        --exclude-dir=node_modules \
        --exclude-dir=.git \
        --exclude-dir=dist \
        2>/dev/null || true
}

# ── DENY cases: synthetic file placed in in-scope dirs ─────────────────────

# Test 1: context/ dir — token detected
DENY_CTX=$(mktemp "$CODEGEN_ROOT/context/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$DENY_CTX")
printf 'combobulate' >"$DENY_CTX"
RESULT=$(scan_dir "$CODEGEN_ROOT/context")
assert_nonempty "DENY: combobulate token in context/ is detected" "$RESULT"
rm -f "$DENY_CTX"

# Test 2: shared/ dir — token detected
DENY_SHARED=$(mktemp "$CODEGEN_ROOT/shared/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$DENY_SHARED")
printf 'combobulate' >"$DENY_SHARED"
RESULT=$(scan_dir "$CODEGEN_ROOT/shared")
assert_nonempty "DENY: combobulate token in shared/ is detected" "$RESULT"
rm -f "$DENY_SHARED"

# Test 3: harnesses/ dir — token detected
DENY_HARNESS=$(mktemp "$CODEGEN_ROOT/harnesses/no-consumer-name-test-XXXXXX.sh")
TMPFILES+=("$DENY_HARNESS")
printf 'combobulate' >"$DENY_HARNESS"
RESULT=$(scan_dir "$CODEGEN_ROOT/harnesses")
assert_nonempty "DENY: combobulate token in harnesses/ is detected" "$RESULT"
rm -f "$DENY_HARNESS"

# Test 4: templates/ dir — token detected
DENY_TMPL=$(mktemp "$CODEGEN_ROOT/templates/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$DENY_TMPL")
printf 'combobulate' >"$DENY_TMPL"
RESULT=$(scan_dir "$CODEGEN_ROOT/templates")
assert_nonempty "DENY: combobulate token in templates/ is detected" "$RESULT"
rm -f "$DENY_TMPL"

# Test 5: repo root file — token detected
DENY_ROOT=$(mktemp "$CODEGEN_ROOT/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$DENY_ROOT")
printf 'combobulate' >"$DENY_ROOT"
RESULT=$(scan)
assert_nonempty "DENY: combobulate token at repo root is detected" "$RESULT"
rm -f "$DENY_ROOT"

# ── ALLOW cases: token placed in excluded dirs ──────────────────────────────

# Test 6: codegen/pitches/ — excluded, not detected
PITCHES_DIR="$CODEGEN_ROOT/codegen/pitches"
mkdir -p "$PITCHES_DIR"
ALLOW_PITCH=$(mktemp "$PITCHES_DIR/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$ALLOW_PITCH")
printf 'combobulate' >"$ALLOW_PITCH"
RESULT=$(scan | grep "$ALLOW_PITCH" || true)
assert_empty "ALLOW: combobulate in codegen/pitches/ is excluded from scan" "$RESULT"
rm -f "$ALLOW_PITCH"

# Test 7: codegen/logging/ — excluded dir, not detected
LOGGING_DIR="$CODEGEN_ROOT/codegen/logging"
mkdir -p "$LOGGING_DIR"
ALLOW_LOG=$(mktemp "$LOGGING_DIR/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$ALLOW_LOG")
printf 'combobulate' >"$ALLOW_LOG"
RESULT=$(scan | grep "$ALLOW_LOG" || true)
assert_empty "ALLOW: combobulate in codegen/logging/ is excluded from scan" "$RESULT"
rm -f "$ALLOW_LOG"

# Test 8: tmp/ — excluded, not detected
TMP_DIR="$CODEGEN_ROOT/tmp"
mkdir -p "$TMP_DIR"
ALLOW_TMP=$(mktemp "$TMP_DIR/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$ALLOW_TMP")
printf 'combobulate' >"$ALLOW_TMP"
RESULT=$(scan | grep "$ALLOW_TMP" || true)
assert_empty "ALLOW: combobulate in tmp/ is excluded from scan" "$RESULT"
rm -f "$ALLOW_TMP"

# ── Case-variant tests ──────────────────────────────────────────────────────

# Test 9: lowercase 'combobulate'
CASE_FILE=$(mktemp "$CODEGEN_ROOT/shared/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$CASE_FILE")
printf 'combobulate' >"$CASE_FILE"
RESULT=$(scan_dir "$CODEGEN_ROOT/shared")
assert_nonempty "DENY: lowercase 'combobulate' is detected" "$RESULT"
rm -f "$CASE_FILE"

# Test 10: uppercase 'COMBOBULATE'
CASE_FILE2=$(mktemp "$CODEGEN_ROOT/shared/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$CASE_FILE2")
printf 'COMBOBULATE' >"$CASE_FILE2"
RESULT=$(scan_dir "$CODEGEN_ROOT/shared")
assert_nonempty "DENY: uppercase 'COMBOBULATE' is detected" "$RESULT"
rm -f "$CASE_FILE2"

# Test 11: mixed-case 'Combobulate'
CASE_FILE3=$(mktemp "$CODEGEN_ROOT/shared/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$CASE_FILE3")
printf 'Combobulate' >"$CASE_FILE3"
RESULT=$(scan_dir "$CODEGEN_ROOT/shared")
assert_nonempty "DENY: mixed-case 'Combobulate' is detected" "$RESULT"
rm -f "$CASE_FILE3"

# ── Edge cases ──────────────────────────────────────────────────────────────

# Test 12: empty-result on clean tree (after removing synthetic files above)
# All synthetic files are removed by this point via rm -f calls above.
LIVE_RESULT=$(scan)
assert_empty "LIVE: actual tree has no 'combobulate' tokens" "$LIVE_RESULT"

# Test 13: scan of a dir with no matching files returns empty
CLEAN_DIR=$(mktemp -d)
TMPDIRS+=("$CLEAN_DIR")
printf 'hello world' >"$CLEAN_DIR/clean.md"
RESULT=$(grep -rIl -i 'combobulate' "$CLEAN_DIR" 2>/dev/null || true)
assert_empty "EDGE: scan of clean dir returns empty" "$RESULT"

# Test 14: file with nearby-but-not-matching content is not flagged
NEARBY_FILE=$(mktemp "$CODEGEN_ROOT/shared/no-consumer-name-test-XXXXXX.md")
TMPFILES+=("$NEARBY_FILE")
printf 'combine cobble gobble' >"$NEARBY_FILE"
RESULT=$(grep -rIl -i 'combobulate' "$NEARBY_FILE" 2>/dev/null || true)
assert_empty "EDGE: non-matching content not flagged" "$RESULT"
rm -f "$NEARBY_FILE"

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
