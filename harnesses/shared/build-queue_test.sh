#!/usr/bin/env bash
# build-queue_test.sh — unit tests for build-queue.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPER="$SCRIPT_DIR/build-queue.sh"
CLAUDE_BUILD="$SCRIPT_DIR/../claude/claude-build.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    case "$haystack" in
    *"$needle"*)
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
        ;;
    *)
        printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
        ;;
    esac
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    case "$haystack" in
    *"$needle"*)
        printf 'FAIL: %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
        ;;
    *)
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
        ;;
    esac
}

# ── Temp workspace ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d)
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"

# ── Fake codegen-build stub builder ───────────────────────────────────────────
# Records argv to CALL_LOG. If STUB_SHIP=1 (default), moves pitch ready→shipped.
# Exits with STUB_EXIT (default 0). STUB_EXTRA_READY creates extra pitch in ready/.
make_stub() {
    local fake_dir="$1"
    cat >"$fake_dir/codegen-build" <<'STUB'
#!/usr/bin/env bash
# Fake codegen-build for build-queue tests
CALL_LOG="${STUB_CALL_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$CALL_LOG"

# Parse the pitch path from args (last arg after --)
pitch_path=""
found_sep=0
for a in "$@"; do
    if [ "$found_sep" = "1" ]; then
        pitch_path="$a"
        break
    fi
    [ "$a" = "--" ] && found_sep=1
done

# Strip leading @ if present (claude mention prefix)
pitch_path="${pitch_path#@}"

if [ "${STUB_SHIP:-1}" = "1" ] && [ -n "$pitch_path" ]; then
    slug="$(basename "$pitch_path" .md)"
    ready_path="$PWD/$pitch_path"
    shipped_dir="$PWD/codegen/pitches/shipped"
    mkdir -p "$shipped_dir"
    if [ -f "$ready_path" ]; then
        mv "$ready_path" "$shipped_dir/$slug.md"
    fi
fi

# If stub wants to create an extra ready pitch (refill test).
# Uses a sentinel file so the refill only happens once (avoids re-creating
# the pitch on subsequent children and breaking the success check).
if [ -n "${STUB_EXTRA_READY:-}" ] && [ -n "${STUB_EXTRA_SENTINEL:-}" ]; then
    if [ ! -f "${STUB_EXTRA_SENTINEL}" ]; then
        touch "${STUB_EXTRA_SENTINEL}"
        printf 'extra pitch content\n' >"$PWD/codegen/pitches/ready/${STUB_EXTRA_READY}.md"
    fi
fi

exit "${STUB_EXIT:-0}"
STUB
    chmod +x "$fake_dir/codegen-build"
}

# ── Helper: make a minimal repo workspace ─────────────────────────────────────
make_workspace() {
    local root="$1"
    mkdir -p "$root/codegen/pitches/ready"
    mkdir -p "$root/codegen/pitches/shipped"
    mkdir -p "$root/codegen/logging"
    mkdir -p "$root/fake-codegen-bin"
    make_stub "$root/fake-codegen-bin"
}

# ── Test T1: empty ready/ → exit 0, "no ready pitches" message ────────────────
T1_ROOT="$TMP_ROOT/t1"
make_workspace "$T1_ROOT"

T1_EXIT=0
T1_OUT=$(
    cd "$T1_ROOT"
    OCG_CODEGEN_DIR="$T1_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T1_EXIT=$?

assert_eq "T1: empty ready/ exits 0" "0" "$T1_EXIT"
assert_contains "T1: no ready pitches message" "no ready pitches" "$T1_OUT"

# ── Test T2: single pitch, happy path → shipped, exit 0 ───────────────────────
T2_ROOT="$TMP_ROOT/t2"
make_workspace "$T2_ROOT"
printf 'Pitch: alpha\n' >"$T2_ROOT/codegen/pitches/ready/alpha.md"

T2_CALL_LOG="$T2_ROOT/calls.log"
T2_EXIT=0
T2_OUT=$(
    cd "$T2_ROOT"
    STUB_CALL_LOG="$T2_CALL_LOG" \
        OCG_CODEGEN_DIR="$T2_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T2_EXIT=$?

assert_eq "T2: single pitch exits 0" "0" "$T2_EXIT"
assert_contains "T2: shipped message" "shipped" "$T2_OUT"
assert_eq "T2: pitch moved to shipped" "1" "$([ -f "$T2_ROOT/codegen/pitches/shipped/alpha.md" ] && printf '1' || printf '0')"
assert_eq "T2: pitch removed from ready" "0" "$([ -f "$T2_ROOT/codegen/pitches/ready/alpha.md" ] && printf '1' || printf '0')"

# ── Test T3: child exits non-zero → FAILED, exit 1, others untouched ──────────
T3_ROOT="$TMP_ROOT/t3"
make_workspace "$T3_ROOT"
printf 'Pitch: aaa\n' >"$T3_ROOT/codegen/pitches/ready/aaa.md"
printf 'Pitch: bbb\n' >"$T3_ROOT/codegen/pitches/ready/bbb.md"
printf 'Pitch: ccc\n' >"$T3_ROOT/codegen/pitches/ready/ccc.md"

T3_CALL_LOG="$T3_ROOT/calls.log"
T3_EXIT=0
T3_OUT=$(
    cd "$T3_ROOT"
    # aaa fails, bbb and ccc should not be attempted
    STUB_CALL_LOG="$T3_CALL_LOG" \
        STUB_EXIT=1 \
        STUB_SHIP=0 \
        OCG_CODEGEN_DIR="$T3_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T3_EXIT=$?

assert_eq "T3: child exits non-zero → driver exits 1" "1" "$T3_EXIT"
# Only one call should have been made (the first slug alphabetically: aaa)
T3_CALLS=$(grep -c '.' "$T3_CALL_LOG" 2>/dev/null || printf '0')
assert_eq "T3: only one child spawned (halt on failure)" "1" "$T3_CALLS"
# bbb and ccc remain in ready/
assert_eq "T3: bbb untouched in ready" "1" "$([ -f "$T3_ROOT/codegen/pitches/ready/bbb.md" ] && printf '1' || printf '0')"
assert_eq "T3: ccc untouched in ready" "1" "$([ -f "$T3_ROOT/codegen/pitches/ready/ccc.md" ] && printf '1' || printf '0')"

# ── Test T4: child exits 0 but not shipped (STUB_SHIP=0) → FAILED ─────────────
T4_ROOT="$TMP_ROOT/t4"
make_workspace "$T4_ROOT"
printf 'Pitch: gamma\n' >"$T4_ROOT/codegen/pitches/ready/gamma.md"

T4_EXIT=0
(
    cd "$T4_ROOT"
    STUB_EXIT=0 \
        STUB_SHIP=0 \
        OCG_CODEGEN_DIR="$T4_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude >/dev/null 2>&1
) || T4_EXIT=$?

assert_eq "T4: exit 0 but not-shipped treated as FAILED → exit 1" "1" "$T4_EXIT"
# Pitch must still be in ready/
assert_eq "T4: pitch still in ready/ (not shipped)" "1" \
    "$([ -f "$T4_ROOT/codegen/pitches/ready/gamma.md" ] && printf '1' || printf '0')"

# ── Test T5: two pitches, no deps → both shipped in lexical order ──────────────
T5_ROOT="$TMP_ROOT/t5"
make_workspace "$T5_ROOT"
printf 'Pitch: mango\n' >"$T5_ROOT/codegen/pitches/ready/mango.md"
printf 'Pitch: apple\n' >"$T5_ROOT/codegen/pitches/ready/apple.md"

T5_CALL_LOG="$T5_ROOT/calls.log"
T5_EXIT=0
T5_OUT=$(
    cd "$T5_ROOT"
    STUB_CALL_LOG="$T5_CALL_LOG" \
        OCG_CODEGEN_DIR="$T5_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T5_EXIT=$?

assert_eq "T5: two pitches exit 0" "0" "$T5_EXIT"
T5_FIRST="$(head -1 "$T5_CALL_LOG" | grep -o 'ready/[^.]*\.md' | sed 's|.*/||;s|\.md||')"
T5_SECOND="$(tail -1 "$T5_CALL_LOG" | grep -o 'ready/[^.]*\.md' | sed 's|.*/||;s|\.md||')"
assert_eq "T5: lexical order — apple first" "apple" "$T5_FIRST"
assert_eq "T5: lexical order — mango second" "mango" "$T5_SECOND"

# ── Test T6: cyclic deps → exit 3, nothing shipped ────────────────────────────
T6_ROOT="$TMP_ROOT/t6"
make_workspace "$T6_ROOT"
printf 'Blocks-on: beta\n' >"$T6_ROOT/codegen/pitches/ready/alpha.md"
printf 'Blocks-on: alpha\n' >"$T6_ROOT/codegen/pitches/ready/beta.md"

T6_CALL_LOG="$T6_ROOT/calls.log"
T6_EXIT=0
T6_STDERR=$(
    cd "$T6_ROOT"
    STUB_CALL_LOG="$T6_CALL_LOG" \
        OCG_CODEGEN_DIR="$T6_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1 >/dev/null
) || T6_EXIT=$?

assert_eq "T6: cyclic deps → exit 3" "3" "$T6_EXIT"
assert_contains "T6: cycle error reported to stderr" "cyclic" "$T6_STDERR"
T6_CALLS=$(grep -c '.' "$T6_CALL_LOG" 2>/dev/null || printf '0')
assert_eq "T6: zero children spawned on cycle" "0" "$T6_CALLS"

# ── Test T7: topo order — A blocks-on B → B built first ──────────────────────
T7_ROOT="$TMP_ROOT/t7"
make_workspace "$T7_ROOT"
printf 'Blocks-on: base-pitch\n' >"$T7_ROOT/codegen/pitches/ready/top-feature.md"
printf 'Pitch: base-pitch\n' >"$T7_ROOT/codegen/pitches/ready/base-pitch.md"

T7_CALL_LOG="$T7_ROOT/calls.log"
T7_EXIT=0
T7_OUT=$(
    cd "$T7_ROOT"
    STUB_CALL_LOG="$T7_CALL_LOG" \
        OCG_CODEGEN_DIR="$T7_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T7_EXIT=$?

assert_eq "T7: topo ordering exits 0" "0" "$T7_EXIT"
T7_FIRST="$(head -1 "$T7_CALL_LOG" | grep -o 'ready/[^.]*\.md' | sed 's|.*/||;s|\.md||')"
T7_SECOND="$(sed -n '2p' "$T7_CALL_LOG" | grep -o 'ready/[^.]*\.md' | sed 's|.*/||;s|\.md||')"
assert_eq "T7: dependency (base-pitch) built first" "base-pitch" "$T7_FIRST"
assert_eq "T7: dependent (top-feature) built second" "top-feature" "$T7_SECOND"

# ── Test T8: harness param — claude uses @-mention, pi uses bare path ─────────
T8_ROOT="$TMP_ROOT/t8"
make_workspace "$T8_ROOT"
printf 'Pitch: pitch-x\n' >"$T8_ROOT/codegen/pitches/ready/pitch-x.md"

T8_CALL_LOG_CLAUDE="$T8_ROOT/calls_claude.log"
T8_EXIT_CLAUDE=0
(
    cd "$T8_ROOT"
    STUB_CALL_LOG="$T8_CALL_LOG_CLAUDE" \
        OCG_CODEGEN_DIR="$T8_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude >/dev/null 2>&1
) || T8_EXIT_CLAUDE=$?

assert_eq "T8: claude harness exits 0" "0" "$T8_EXIT_CLAUDE"
T8_CLAUDE_ARGS="$(cat "$T8_CALL_LOG_CLAUDE" 2>/dev/null || true)"
assert_contains "T8: claude uses @-mention prefix" "@codegen/pitches/ready/pitch-x.md" "$T8_CLAUDE_ARGS"
assert_contains "T8: claude passes --harness=claude" "--harness=claude" "$T8_CLAUDE_ARGS"

# Re-create pitch for pi test (was shipped in claude test)
printf 'Pitch: pitch-x\n' >"$T8_ROOT/codegen/pitches/ready/pitch-x.md"
rm -f "$T8_ROOT/codegen/pitches/shipped/pitch-x.md"

T8_CALL_LOG_PI="$T8_ROOT/calls_pi.log"
T8_EXIT_PI=0
(
    cd "$T8_ROOT"
    STUB_CALL_LOG="$T8_CALL_LOG_PI" \
        OCG_CODEGEN_DIR="$T8_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=pi >/dev/null 2>&1
) || T8_EXIT_PI=$?

assert_eq "T8: pi harness exits 0" "0" "$T8_EXIT_PI"
T8_PI_ARGS="$(cat "$T8_CALL_LOG_PI" 2>/dev/null || true)"
assert_contains "T8: pi passes --harness=pi" "--harness=pi" "$T8_PI_ARGS"
# pi uses bare path (no @ prefix)
assert_not_contains "T8: pi does not use @-mention" "@codegen/" "$T8_PI_ARGS"
assert_contains "T8: pi uses bare path" "codegen/pitches/ready/pitch-x.md" "$T8_PI_ARGS"

# ── Test T9 (part A): refill — new pitch appears mid-run and gets picked up ───
T9_ROOT="$TMP_ROOT/t9"
make_workspace "$T9_ROOT"
printf 'Pitch: first\n' >"$T9_ROOT/codegen/pitches/ready/first.md"

T9_CALL_LOG="$T9_ROOT/calls.log"
T9_SENTINEL="$T9_ROOT/refill.done"
T9_EXIT=0
T9_OUT=$(
    cd "$T9_ROOT"
    # When first pitch is built, stub creates a new "second" pitch in ready/.
    # Sentinel prevents re-creation on second child invocation.
    STUB_CALL_LOG="$T9_CALL_LOG" \
        STUB_EXTRA_READY="second" \
        STUB_EXTRA_SENTINEL="$T9_SENTINEL" \
        OCG_CODEGEN_DIR="$T9_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T9_EXIT=$?

assert_eq "T9: refill — both pitches exit 0" "0" "$T9_EXIT"
T9_CALLS=$(grep -c '.' "$T9_CALL_LOG" 2>/dev/null || printf '0')
assert_eq "T9: refill — two children spawned (first + refilled second)" "2" "$T9_CALLS"

# ── Test T9 (part B): --queue with slug arg → exit 2 from claude-build.sh ─────
# Test the launcher-level guard directly
T9B_EXIT=0
T9B_STDERR=$(
    # We need a valid repo root; use TMP_ROOT with a ready/ dir
    mkdir -p "$TMP_ROOT/t9b/codegen/pitches/ready"
    cd "$TMP_ROOT/t9b"
    bash "$CLAUDE_BUILD" --queue some-extra-slug 2>&1 >/dev/null
) || T9B_EXIT=$?

assert_eq "T9B: --queue with extra slug arg exits 2" "2" "$T9B_EXIT"
assert_contains "T9B: error message mentions extra arg" "some-extra-slug" "$T9B_STDERR"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
