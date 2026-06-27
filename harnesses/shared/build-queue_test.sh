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

# Per-attempt counter so retries can emit DIFFERENT bodies / ship on a later attempt.
attempt=1
if [ -n "${STUB_ATTEMPT_FILE:-}" ]; then
    if [ -r "$STUB_ATTEMPT_FILE" ]; then
        attempt="$(cat "$STUB_ATTEMPT_FILE" 2>/dev/null || printf '1')"
    fi
    printf '%s' "$((attempt + 1))" >"$STUB_ATTEMPT_FILE"
fi

# Emit JSONL body to stdout so build-queue's `tee "$JSONL"` captures it.
# STUB_JSONL_BODY_<N> takes precedence for attempt N; else STUB_JSONL_BODY.
eval "body=\"\${STUB_JSONL_BODY_${attempt}:-\${STUB_JSONL_BODY:-}}\""
if [ -n "${body:-}" ]; then
    printf '%s\n' "$body"
fi

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

eval "ship_flag=\"\${STUB_SHIP_${attempt}:-\${STUB_SHIP:-1}}\""
if [ "${ship_flag:-1}" = "1" ] && [ -n "$pitch_path" ]; then
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

eval "exit_code=\"\${STUB_EXIT_${attempt}:-\${STUB_EXIT:-0}}\""
exit "${exit_code}"
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
    # aaa fails, bbb and ccc should not be attempted.
    # Emit a deterministic result record so is_transient returns false (no retry).
    STUB_CALL_LOG="$T3_CALL_LOG" \
        STUB_EXIT=1 \
        STUB_SHIP=0 \
        STUB_JSONL_BODY='{"type":"result","result":"compile error: missing module","session_id":"sT3"}' \
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
    # Emit a result record so is_transient returns false — exit 0 not-shipped is
    # a deterministic failure (no retry expected).
    STUB_EXIT=0 \
        STUB_SHIP=0 \
        STUB_JSONL_BODY='{"type":"result","result":"finished but not shipped","session_id":"sT4"}' \
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

# ── Test T10: transient error → retry, then ship ─────────────────────────────
T10_ROOT="$TMP_ROOT/t10"
make_workspace "$T10_ROOT"
printf 'Pitch: alpha\n' >"$T10_ROOT/codegen/pitches/ready/alpha.md"

T10_CALL_LOG="$T10_ROOT/calls.log"
T10_ATTEMPT_FILE="$T10_ROOT/attempt"
T10_TRANSIENT='{"type":"system","subtype":"api_error","error":{"message":"socket connection was closed"}}'
T10_RESULT='{"type":"result","result":"shipped ok","session_id":"s2"}'

T10_EXIT=0
T10_OUT=$(
    cd "$T10_ROOT"
    STUB_CALL_LOG="$T10_CALL_LOG" \
        STUB_ATTEMPT_FILE="$T10_ATTEMPT_FILE" \
        STUB_JSONL_BODY_1="$T10_TRANSIENT" \
        STUB_EXIT_1=1 \
        STUB_SHIP_1=0 \
        STUB_JSONL_BODY_2="$T10_RESULT" \
        STUB_SHIP_2=1 \
        STUB_EXIT_2=0 \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=3 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T10_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T10_EXIT=$?

assert_eq "T10: transient retry exits 0" "0" "$T10_EXIT"
assert_eq "T10: slug shipped after retry" "1" \
    "$([ -f "$T10_ROOT/codegen/pitches/shipped/alpha.md" ] && printf '1' || printf '0')"
T10_CALLS="$(grep -c '.' "$T10_CALL_LOG" 2>/dev/null || printf '0')"
[ "$T10_CALLS" -ge 2 ] &&
    pass=$((pass + 1)) ||
    {
        printf 'FAIL: T10 expected >=2 calls got %s\n' "$T10_CALLS"
        fail=$((fail + 1))
    }

# ── Test T11: no result record (crashed) → retry, then ship ──────────────────
T11_ROOT="$TMP_ROOT/t11"
make_workspace "$T11_ROOT"
printf 'Pitch: alpha\n' >"$T11_ROOT/codegen/pitches/ready/alpha.md"

T11_CALL_LOG="$T11_ROOT/calls.log"
T11_ATTEMPT_FILE="$T11_ROOT/attempt"
T11_NO_RESULT='{"type":"system","subtype":"init","session_id":"s0"}'
T11_RESULT='{"type":"result","result":"ok","session_id":"s2"}'

T11_EXIT=0
(
    cd "$T11_ROOT"
    STUB_CALL_LOG="$T11_CALL_LOG" \
        STUB_ATTEMPT_FILE="$T11_ATTEMPT_FILE" \
        STUB_JSONL_BODY_1="$T11_NO_RESULT" \
        STUB_EXIT_1=1 \
        STUB_SHIP_1=0 \
        STUB_JSONL_BODY_2="$T11_RESULT" \
        STUB_SHIP_2=1 \
        STUB_EXIT_2=0 \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=3 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T11_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude >/dev/null 2>&1
) || T11_EXIT=$?

assert_eq "T11: no-result retry exits 0" "0" "$T11_EXIT"
assert_eq "T11: slug shipped after no-result retry" "1" \
    "$([ -f "$T11_ROOT/codegen/pitches/shipped/alpha.md" ] && printf '1' || printf '0')"

# ── Test T12: deterministic failure → fast-fail, no retry, exit 1 ────────────
T12_ROOT="$TMP_ROOT/t12"
make_workspace "$T12_ROOT"
printf 'Pitch: alpha\n' >"$T12_ROOT/codegen/pitches/ready/alpha.md"

T12_CALL_LOG="$T12_ROOT/calls.log"
T12_DET='{"type":"result","result":"compile error: undefined fn","session_id":"sX"}'

T12_EXIT=0
T12_OUT=$(
    cd "$T12_ROOT"
    STUB_CALL_LOG="$T12_CALL_LOG" \
        STUB_JSONL_BODY="$T12_DET" \
        STUB_EXIT=1 \
        STUB_SHIP=0 \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=3 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T12_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T12_EXIT=$?

assert_eq "T12: deterministic failure exits 1" "1" "$T12_EXIT"
T12_CALLS="$(grep -c '.' "$T12_CALL_LOG" 2>/dev/null || printf '0')"
assert_eq "T12: exactly 1 call (no retry)" "1" "$T12_CALLS"
assert_eq "T12: result text in stderr output" "1" \
    "$(printf '%s' "$T12_OUT" | grep -qF 'compile error' && printf '1' || printf '0')"
assert_eq "T12: slug still in ready (not shipped)" "1" \
    "$([ -f "$T12_ROOT/codegen/pitches/ready/alpha.md" ] && printf '1' || printf '0')"

# ── Test T13: retries exhausted → exit 1 after MAX+1 total attempts ───────────
T13_ROOT="$TMP_ROOT/t13"
make_workspace "$T13_ROOT"
printf 'Pitch: alpha\n' >"$T13_ROOT/codegen/pitches/ready/alpha.md"

T13_CALL_LOG="$T13_ROOT/calls.log"
T13_TRANSIENT='{"type":"system","subtype":"api_error","error":{"message":"socket connection was closed"}}'

T13_EXIT=0
(
    cd "$T13_ROOT"
    STUB_CALL_LOG="$T13_CALL_LOG" \
        STUB_JSONL_BODY="$T13_TRANSIENT" \
        STUB_EXIT=1 \
        STUB_SHIP=0 \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=2 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T13_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude >/dev/null 2>&1
) || T13_EXIT=$?

assert_eq "T13: retries exhausted exits 1" "1" "$T13_EXIT"
T13_CALLS="$(grep -c '.' "$T13_CALL_LOG" 2>/dev/null || printf '0')"
assert_eq "T13: total calls = 3 (1 initial + 2 retries)" "3" "$T13_CALLS"
assert_eq "T13: slug still in ready after exhaustion" "1" \
    "$([ -f "$T13_ROOT/codegen/pitches/ready/alpha.md" ] && printf '1' || printf '0')"

# ── Test T14: is_gate_green unit tests ───────────────────────────────────────
# Source the helper with stubs so is_gate_green is callable directly.
# We override LOG_DIR to a temp directory for isolation.
T14_ROOT="$TMP_ROOT/t14"
mkdir -p "$T14_ROOT/codegen/logging"

# Source the helper (we need is_gate_green; most of the script is safe to load
# since no main loop runs without a --harness flag causing exit 2, but we skip
# that by sourcing and testing the function directly).
T14_LOG_DIR="$T14_ROOT/codegen/logging"

# Extract and evaluate just is_gate_green so we don't pull in the arg-parser
# which exits 2 without a --harness flag.
eval "$(sed -n '/^is_gate_green()/,/^}/p' "$HELPER")"

# Override LOG_DIR for these unit tests.
LOG_DIR="$T14_LOG_DIR"

START_TS="20260601_120000"
SLUG="my-pitch"

# T14-A: qualifying log with ALL CLEAR → returns 0
T14A_LOG="$T14_LOG_DIR/${START_TS}_${SLUG}_session.md"
printf 'Some content\nALL CLEAR ✅\nMore content\n' >"$T14A_LOG"
T14A_RC=0
is_gate_green "$SLUG" "$START_TS" || T14A_RC=$?
assert_eq "T14-A: ALL CLEAR + ts>=start → 0" "0" "$T14A_RC"

# T14-B: stale log (ts < start_ts) with ALL CLEAR → returns 1
STALE_TS="20260601_115959"
T14B_LOG="$T14_LOG_DIR/${STALE_TS}_${SLUG}_session.md"
printf 'ALL CLEAR ✅\n' >"$T14B_LOG"
rm -f "$T14A_LOG"
T14B_RC=0
is_gate_green "$SLUG" "$START_TS" || T14B_RC=$?
assert_eq "T14-B: ALL CLEAR but ts<start (stale) → 1" "1" "$T14B_RC"

# T14-C: qualifying log exists but NO ALL CLEAR → returns 1
T14C_LOG="$T14_LOG_DIR/${START_TS}_${SLUG}_session.md"
printf 'FAILED ❌\nNo gate green here\n' >"$T14C_LOG"
rm -f "$T14B_LOG"
T14C_RC=0
is_gate_green "$SLUG" "$START_TS" || T14C_RC=$?
assert_eq "T14-C: ts>=start but no ALL CLEAR → 1" "1" "$T14C_RC"

# T14-D: no matching log at all → returns 1
rm -f "$T14C_LOG"
T14D_RC=0
is_gate_green "$SLUG" "$START_TS" || T14D_RC=$?
assert_eq "T14-D: no matching log → 1" "1" "$T14D_RC"

# T14-E: two logs, newest has ALL CLEAR → 0; oldest also has ALL CLEAR
OLDER_TS="20260601_120001"
NEWER_TS="20260601_130000"
T14E_OLD="$T14_LOG_DIR/${OLDER_TS}_${SLUG}_session.md"
T14E_NEW="$T14_LOG_DIR/${NEWER_TS}_${SLUG}_session.md"
printf 'ALL CLEAR ✅\n' >"$T14E_OLD"
printf 'ALL CLEAR ✅\n' >"$T14E_NEW"
T14E_RC=0
is_gate_green "$SLUG" "$START_TS" || T14E_RC=$?
assert_eq "T14-E: two logs, newest (ts-greatest) has ALL CLEAR → 0" "0" "$T14E_RC"

# T14-F: two logs, newest lacks ALL CLEAR though older has it → 1 (newest wins)
printf 'FAILED ❌\n' >"$T14E_NEW"
T14F_RC=0
is_gate_green "$SLUG" "$START_TS" || T14F_RC=$?
assert_eq "T14-F: newest lacks ALL CLEAR though older has it → 1" "1" "$T14F_RC"
rm -f "$T14E_OLD" "$T14E_NEW"

# T14-G: slug-suffix isolation — log for "bar-my-pitch" does NOT match "my-pitch"
SUFFIX_SLUG="bar-${SLUG}"
T14G_LOG="$T14_LOG_DIR/${START_TS}_${SUFFIX_SLUG}_session.md"
printf 'ALL CLEAR ✅\n' >"$T14G_LOG"
T14G_RC=0
is_gate_green "$SLUG" "$START_TS" || T14G_RC=$?
assert_eq "T14-G: bar-my-pitch log does not satisfy is_gate_green my-pitch → 1" "1" "$T14G_RC"
rm -f "$T14G_LOG"

# ── Test T15: gate-green / commit-pending retry integration ───────────────────
# Child fails non-transient (has result record) but a session log with ALL CLEAR
# appears in logging/ with ts >= child-start ts → queue retries instead of halt.
# On second attempt the stub ships the pitch.
T15_ROOT="$TMP_ROOT/t15"
make_workspace "$T15_ROOT"
printf 'Pitch: beta\n' >"$T15_ROOT/codegen/pitches/ready/beta.md"

T15_CALL_LOG="$T15_ROOT/calls.log"
T15_ATTEMPT_FILE="$T15_ROOT/attempt"
T15_DET='{"type":"result","result":"committed but not shipped","session_id":"sT15"}'

# Stub that writes an ALL CLEAR session log on attempt 1 then ships on attempt 2.
cat >"$T15_ROOT/fake-codegen-bin/codegen-build" <<'STUB15'
#!/usr/bin/env bash
CALL_LOG="${STUB_CALL_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$CALL_LOG"

attempt=1
if [ -n "${STUB_ATTEMPT_FILE:-}" ]; then
    if [ -r "$STUB_ATTEMPT_FILE" ]; then
        attempt="$(cat "$STUB_ATTEMPT_FILE" 2>/dev/null || printf '1')"
    fi
    printf '%s' "$((attempt + 1))" >"$STUB_ATTEMPT_FILE"
fi

# Parse pitch path from args
pitch_path=""
found_sep=0
for a in "$@"; do
    [ "$found_sep" = "1" ] && { pitch_path="$a"; break; }
    [ "$a" = "--" ] && found_sep=1
done
pitch_path="${pitch_path#@}"
slug="$(basename "$pitch_path" .md)"

if [ "$attempt" = "1" ]; then
    # Emit deterministic result (so is_transient returns 1 / not transient).
    printf '{"type":"result","result":"gate passed but not shipped","session_id":"sT15"}\n'
    # Write a session log with ALL CLEAR for this slug, using a ts >= child's ts.
    log_ts="$(date -u +%Y%m%d_%H%M%S)"
    mkdir -p "$PWD/codegen/logging"
    printf 'ALL CLEAR ✅\n' >"$PWD/codegen/logging/${log_ts}_${slug}_session.md"
    exit 1
fi

# Attempt 2: ship normally.
if [ -n "$pitch_path" ]; then
    shipped_dir="$PWD/codegen/pitches/shipped"
    mkdir -p "$shipped_dir"
    ready_path="$PWD/$pitch_path"
    [ -f "$ready_path" ] && mv "$ready_path" "$shipped_dir/$slug.md"
fi
exit 0
STUB15
chmod +x "$T15_ROOT/fake-codegen-bin/codegen-build"

T15_EXIT=0
T15_OUT=$(
    cd "$T15_ROOT"
    STUB_CALL_LOG="$T15_CALL_LOG" \
        STUB_ATTEMPT_FILE="$T15_ATTEMPT_FILE" \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=3 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T15_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T15_EXIT=$?

assert_eq "T15: gate-green/commit-pending retries and eventually ships → 0" "0" "$T15_EXIT"
assert_eq "T15: slug shipped after gate-green retry" "1" \
    "$([ -f "$T15_ROOT/codegen/pitches/shipped/beta.md" ] && printf '1' || printf '0')"
T15_CALLS="$(grep -c '.' "$T15_CALL_LOG" 2>/dev/null || printf '0')"
assert_eq "T15: exactly 2 calls (attempt 1 + 1 retry)" "2" "$T15_CALLS"
assert_contains "T15: gate-green log line emitted" "gate green, commit pending" "$T15_OUT"

# T15-B: gate-green exhausts MAX_RETRIES → exit 1 (bounded by budget)
T15B_ROOT="$TMP_ROOT/t15b"
make_workspace "$T15B_ROOT"
printf 'Pitch: gamma\n' >"$T15B_ROOT/codegen/pitches/ready/gamma.md"

T15B_CALL_LOG="$T15B_ROOT/calls.log"

# Stub: always emits ALL CLEAR session log but never ships.
cat >"$T15B_ROOT/fake-codegen-bin/codegen-build" <<'STUB15B'
#!/usr/bin/env bash
CALL_LOG="${STUB_CALL_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$CALL_LOG"

pitch_path=""
found_sep=0
for a in "$@"; do
    [ "$found_sep" = "1" ] && { pitch_path="$a"; break; }
    [ "$a" = "--" ] && found_sep=1
done
pitch_path="${pitch_path#@}"
slug="$(basename "$pitch_path" .md)"

printf '{"type":"result","result":"deterministic failure","session_id":"sT15B"}\n'
log_ts="$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$PWD/codegen/logging"
printf 'ALL CLEAR ✅\n' >"$PWD/codegen/logging/${log_ts}_${slug}_session.md"
exit 1
STUB15B
chmod +x "$T15B_ROOT/fake-codegen-bin/codegen-build"

T15B_EXIT=0
(
    cd "$T15B_ROOT"
    STUB_CALL_LOG="$T15B_CALL_LOG" \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=2 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T15B_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude >/dev/null 2>&1
) || T15B_EXIT=$?

assert_eq "T15-B: gate-green exhausts MAX_RETRIES → exit 1" "1" "$T15B_EXIT"
T15B_CALLS="$(grep -c '.' "$T15B_CALL_LOG" 2>/dev/null || printf '0')"
assert_eq "T15-B: total calls = 3 (1 initial + 2 retries = MAX_RETRIES)" "3" "$T15B_CALLS"

# ── Test T16: gate green + HEAD changed but ship-marker absent → ship, no re-spawn ─
# Simulates: child's gate passes (ALL CLEAR), child made a git commit (HEAD moved)
# but did NOT move the pitch file to shipped/. build-queue should detect the
# HEAD-changed case and complete shipping without re-spawning the child.
T16_ROOT="$TMP_ROOT/t16"
make_workspace "$T16_ROOT"
printf 'Pitch: kappa\n' >"$T16_ROOT/codegen/pitches/ready/kappa.md"

# T16 requires a real git repo so HEAD tracking works.
(
    cd "$T16_ROOT"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    printf 'baseline\n' >baseline.txt
    git add baseline.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline"
)

T16_CALL_LOG="$T16_ROOT/calls.log"

# Custom stub: emits ALL CLEAR session log + makes a real git commit in $PWD
# but does NOT move the pitch to shipped/.
cat >"$T16_ROOT/fake-codegen-bin/codegen-build" <<'STUB16'
#!/usr/bin/env bash
CALL_LOG="${STUB_CALL_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$CALL_LOG"

# Parse pitch path from args
pitch_path=""
found_sep=0
for a in "$@"; do
    [ "$found_sep" = "1" ] && { pitch_path="$a"; break; }
    [ "$a" = "--" ] && found_sep=1
done
pitch_path="${pitch_path#@}"
slug="$(basename "$pitch_path" .md)"

# Emit a deterministic result record (not transient).
printf '{"type":"result","result":"gate passed, committed but not shipped","session_id":"sT16"}\n'

# Write ALL CLEAR session log so is_gate_green returns 0.
log_ts="$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$PWD/codegen/logging"
printf 'ALL CLEAR ✅\n' >"$PWD/codegen/logging/${log_ts}_${slug}_session.md"

# Make a real git commit so HEAD changes (simulates committer sub-agent having committed).
printf 'child change\n' >child-change.txt
git add child-change.txt
git -c core.hooksPath=/dev/null commit -q -m "committer: implement $slug"

# Do NOT move pitch to shipped/ — build-queue must detect HEAD-change and ship.
exit 1
STUB16
chmod +x "$T16_ROOT/fake-codegen-bin/codegen-build"

T16_EXIT=0
T16_OUT=$(
    cd "$T16_ROOT"
    STUB_CALL_LOG="$T16_CALL_LOG" \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=3 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T16_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T16_EXIT=$?

assert_eq "T16: gate-green + HEAD-changed + no-ship → exits 0" "0" "$T16_EXIT"
assert_eq "T16: pitch moved to shipped/" "1" \
    "$([ -f "$T16_ROOT/codegen/pitches/shipped/kappa.md" ] && printf '1' || printf '0')"
assert_eq "T16: pitch removed from ready/" "0" \
    "$([ -f "$T16_ROOT/codegen/pitches/ready/kappa.md" ] && printf '1' || printf '0')"
T16_CALLS="$(grep -c '.' "$T16_CALL_LOG" 2>/dev/null || printf '0')"
assert_eq "T16: exactly 1 child call (no re-spawn)" "1" "$T16_CALLS"
assert_contains "T16: stdout contains shipping message" "gate green, already committed — shipping" "$T16_OUT"

# ── T17: per-pitch timeout — slug stays in ready/, queue advances ─────────────
T17_ROOT="$(mktemp -d)"
T17_ROOT="$(cd "$T17_ROOT" && pwd -P)"
mkdir -p "$T17_ROOT/codegen/pitches/ready"
mkdir -p "$T17_ROOT/codegen/pitches/shipped"
mkdir -p "$T17_ROOT/codegen/logging"
mkdir -p "$T17_ROOT/fake-codegen-bin"
printf 'lambda pitch\n' >"$T17_ROOT/codegen/pitches/ready/lambda.md"
(
    cd "$T17_ROOT"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    printf 'baseline\n' >baseline.txt
    git add baseline.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline"
)

# Stub: hangs longer than the budget (simulates a hung child). Bounded at 30s
# (NOT 9999) so a future watchdog-reaping regression fails this test in seconds
# instead of wedging `make test` for hours. Budget is 2s below, so the watchdog
# must reap this well before 30s — a green T17 proves the reap happened.
cat >"$T17_ROOT/fake-codegen-bin/codegen-build" <<'STUB17'
#!/usr/bin/env bash
sleep 30
STUB17
chmod +x "$T17_ROOT/fake-codegen-bin/codegen-build"

T17_EXIT=0
T17_OUT=$(
    cd "$T17_ROOT"
    CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS=2 \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=0 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T17_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T17_EXIT=$?

assert_eq "T17: timeout — queue exits 0 (not a hard failure)" "0" "$T17_EXIT"
assert_eq "T17: timed-out slug stays in ready/" "1" \
    "$([ -f "$T17_ROOT/codegen/pitches/ready/lambda.md" ] && printf '1' || printf '0')"
assert_eq "T17: timed-out slug NOT in shipped/" "0" \
    "$([ -f "$T17_ROOT/codegen/pitches/shipped/lambda.md" ] && printf '1' || printf '0')"
assert_contains "T17: output contains TIMED OUT" "TIMED OUT" "$T17_OUT"
assert_contains "T17: output contains budget seconds" "budget 2s" "$T17_OUT"
rm -rf "$T17_ROOT"

# ── T18: invalid budget env var falls back to 1800 (no crash) ─────────────────
T18_ROOT="$(mktemp -d)"
T18_ROOT="$(cd "$T18_ROOT" && pwd -P)"
mkdir -p "$T18_ROOT/codegen/pitches/ready"
mkdir -p "$T18_ROOT/codegen/pitches/shipped"
mkdir -p "$T18_ROOT/codegen/logging"
mkdir -p "$T18_ROOT/fake-codegen-bin"
printf 'mu pitch\n' >"$T18_ROOT/codegen/pitches/ready/mu.md"
(
    cd "$T18_ROOT"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    printf 'baseline\n' >baseline.txt
    git add baseline.txt
    git -c core.hooksPath=/dev/null commit -q -m "baseline"
)

# Stub: exits 0 and ships immediately
cat >"$T18_ROOT/fake-codegen-bin/codegen-build" <<'STUB18'
#!/usr/bin/env bash
pitch_path=""
found_sep=0
for a in "$@"; do
    [ "$found_sep" = "1" ] && { pitch_path="$a"; break; }
    [ "$a" = "--" ] && found_sep=1
done
pitch_path="${pitch_path#@}"
slug="$(basename "$pitch_path" .md)"
mkdir -p "codegen/pitches/shipped"
cp "codegen/pitches/ready/${slug}.md" "codegen/pitches/shipped/${slug}.md" 2>/dev/null || true
rm -f "codegen/pitches/ready/${slug}.md"
printf '{"type":"result","result":"ok","session_id":"sT18"}\n'
exit 0
STUB18
chmod +x "$T18_ROOT/fake-codegen-bin/codegen-build"

T18_EXIT=0
T18_OUT=$(
    cd "$T18_ROOT"
    CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS=abc \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=0 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T18_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T18_EXIT=$?

assert_eq "T18: invalid budget (abc) — no crash, queue exits 0" "0" "$T18_EXIT"
assert_not_contains "T18: no unbound variable error" "unbound variable" "$T18_OUT"
rm -rf "$T18_ROOT"

# ── Test T19: "Connection closed mid-response" → transient retry, then ship ───
T19_ROOT="$TMP_ROOT/t19"
make_workspace "$T19_ROOT"
printf 'Pitch: delta\n' >"$T19_ROOT/codegen/pitches/ready/delta.md"

T19_CALL_LOG="$T19_ROOT/calls.log"
T19_ATTEMPT_FILE="$T19_ROOT/attempt"
T19_DROP='{"type":"system","subtype":"api_error","error":{"message":"Connection closed mid-response"}}'
T19_RESULT='{"type":"result","result":"shipped ok","session_id":"sT19"}'

T19_EXIT=0
T19_OUT=$(
    cd "$T19_ROOT"
    STUB_CALL_LOG="$T19_CALL_LOG" \
        STUB_ATTEMPT_FILE="$T19_ATTEMPT_FILE" \
        STUB_JSONL_BODY_1="$T19_DROP" \
        STUB_EXIT_1=1 \
        STUB_SHIP_1=0 \
        STUB_JSONL_BODY_2="$T19_RESULT" \
        STUB_SHIP_2=1 \
        STUB_EXIT_2=0 \
        CODEGEN_BUILD_QUEUE_MAX_RETRIES=3 \
        CODEGEN_BUILD_QUEUE_RETRY_DELAYS="0 0 0" \
        OCG_CODEGEN_DIR="$T19_ROOT/fake-codegen-bin" \
        bash "$HELPER" --harness=claude 2>&1
) || T19_EXIT=$?

assert_eq "T19: connection-drop retry exits 0" "0" "$T19_EXIT"
assert_eq "T19: slug shipped after connection-drop retry" "1" \
    "$([ -f "$T19_ROOT/codegen/pitches/shipped/delta.md" ] && printf '1' || printf '0')"
T19_CALLS="$(grep -c '.' "$T19_CALL_LOG" 2>/dev/null || printf '0')"
[ "$T19_CALLS" -ge 2 ] &&
    pass=$((pass + 1)) ||
    {
        printf 'FAIL: T19 expected >=2 calls got %s\n' "$T19_CALLS"
        fail=$((fail + 1))
    }

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
