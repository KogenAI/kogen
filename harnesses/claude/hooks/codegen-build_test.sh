#!/usr/bin/env bash
# codegen-build_test.sh — unit tests for codegen-build, dispatch.sh (claude + pi).
#
# codegen-build has no engine flag: dispatch.sh always execs the deterministic
# Elixir orchestration loop (mix codegen.loop). There is no legacy engine.
#
# Tests:
#  (a) --harness=claude → dispatch.sh execs `mix codegen.loop
#      --harness=claude_code ...` (loop path)
#  (b) --harness=pi → dispatch.sh execs `mix codegen.loop --harness=pi ...`
#  (c) missing --harness exits 2 with usage on stderr
#  (e) exit codes 0/1/2/130 propagate from stub
#  (f) stdout passes through fixture output byte-identical (mix stub's own
#      stdout — not a claude/pi passthrough)
#  (p1) --stack omitted, cwd has mix.exs only → detects phoenix
#  (p2) --stack omitted, cwd has vite.config.js only → detects static
#  (p3) --stack omitted, cwd has BOTH mix.exs and vite.config.js → ambiguous,
#       exit 2
#  (p4) --stack omitted, cwd has neither marker → cannot detect, exit 2
#  (p5) --stack omitted, cwd has self-build markers → detects phoenix
#       (self-build precedence over mix.exs/vite.config.js sniffs)
#  (q1)-(q4) schema-staleness preflight (codegen/manifest.yaml)
#  (pa1) --print-argv on claude leg: exits 0, prints codegen.loop argv, never
#        invokes the stubbed mix binary
#  (pa2) --print-argv on pi leg: same, --harness=pi
#  (pa3) --print-argv performs zero mutation — integrate pre-step skipped
#  (b1) dry-run honesty: --max-budget-usd threads through
#       CODEGEN_BUILD_MAX_BUDGET_USD into the print-argv'd loop argv (claude leg)
#  (b2-pi) same dry-run honesty check on the pi leg
#  (b3) non-adoption: codegen itself never passes --max-budget-usd
#  (u) usage<->parse parity: every parsed flag appears in the usage string
#      and vice versa
#  (snap) public flag surface snapshot: parsed flags == committed fixture
#  (d) dead-export absence: CODEGEN_BUILD_MODEL/EFFORT never exported

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
CODEGEN_BUILD="$CODEGEN_ROOT/codegen-build"
REAL_CLAUDE_HARNESS="$CODEGEN_ROOT/harnesses/claude"
REAL_PI_HARNESS="$CODEGEN_ROOT/harnesses/pi"

# shellcheck source=/dev/null
source "$CODEGEN_ROOT/harnesses/shared/test-stub-lib.sh"

pass=0
fail=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"

    if printf '%s' "$haystack" | grep -Fq -- "$needle" 2>/dev/null; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        if [[ "$haystack" == *"$needle"* ]]; then
            [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
            pass=$((pass + 1))
        else
            printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:200}"
            fail=$((fail + 1))
        fi
    fi
}

# ── Setup: tmp dir ────────────────────────────────────────────────────────────
BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

# Helper: create isolated cb root with its own copy of codegen-build + harnesses
make_cb_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir"
    link_or_copy "$CODEGEN_BUILD" "$dir/codegen-build"
    echo "$dir"
}

make_claude_harness() {
    local cb_root="$1"
    local harness_dir="$cb_root/harnesses/claude"
    mkdir -p "$harness_dir"
    link_or_copy "$REAL_CLAUDE_HARNESS/dispatch.sh" "$harness_dir/dispatch.sh"
    echo "$harness_dir"
}

make_pi_harness() {
    local cb_root="$1"
    local harness_dir="$cb_root/harnesses/pi"
    mkdir -p "$harness_dir"
    link_or_copy "$REAL_PI_HARNESS/dispatch.sh" "$harness_dir/dispatch.sh"
    echo "$harness_dir"
}

# make_mix_stub <dir>
# dispatch.sh always execs `mix codegen.loop ...` (unconditional loop path).
# Stub `mix` so these hermetic tests never invoke a real LLM/ExUnit
# round-trip; captures argv to the file named by $TARGET_ARGS_FILE (or
# /dev/null if unset).
make_mix_stub() {
    local dir="$1"
    mkdir -p "$dir"
    make_stub "$dir/mix" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'
}

# make_codegen_log_stub <dir>
# dispatch.sh preflights `codegen-log --version` before spawning any role.
make_codegen_log_stub() {
    local dir="$1"
    mkdir -p "$dir"
    make_stub "$dir/codegen-log" 'printf "codegen-log root=resolved\n"'
}

# result_ok_body
# Stub writes invocation-scoped loop result and a clear authoritative gate verdict.
# The wrapper validates its success proof against the dispatched cwd's HEAD.
result_ok_body() {
    printf 'pending="${CODEGEN_BUILD_CWD:-.}/codegen/gate-pending"\nmkdir -p "$pending"\ngit -C "${CODEGEN_BUILD_CWD:-.}" init -q\ngit -C "${CODEGEN_BUILD_CWD:-.}" config user.email test@example.com\ngit -C "${CODEGEN_BUILD_CWD:-.}" config user.name test\ngit -C "${CODEGEN_BUILD_CWD:-.}" commit --allow-empty -qm fixture\nhead=$(git -C "${CODEGEN_BUILD_CWD:-.}" rev-parse HEAD)\nprintf "{\\\"invocation_id\\\":\\\"%%s\\\",\\\"slug\\\":\\\"%%s\\\",\\\"status\\\":\\\"%%s\\\",\\\"head\\\":\\\"%%s\\\",\\\"updated_at\\\":\\\"fixture\\\"}\\n" "${RESULT_INVOCATION_ID:-$CODEGEN_BUILD_INVOCATION_ID}" "${RESULT_SLUG:-adhoc}" "${RESULT_STATUS:-success}" "${RESULT_HEAD:-$head}" > "$pending/build-result.json"\nprintf "{\\\"verdict\\\":\\\"%%s\\\"}\\n" "${RESULT_VERDICT:-clear}" > "$pending/gate-result.json"\nexit 0\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# Test (c): missing --harness → exit 2 + usage on stderr
# ─────────────────────────────────────────────────────────────────────────────
CB_C="$(make_cb_root cb_c)"
make_claude_harness "$CB_C" >/dev/null

actual_exit=0
"$CB_C/codegen-build" "some prompt" 2>/dev/null || actual_exit=$?
check "(c) missing --harness exits 2" "2" "$actual_exit"

stderr_c=$("$CB_C/codegen-build" "some prompt" 2>&1 || true)
assert_contains "(c) usage on stderr contains harness keyword" "$stderr_c" "harness"

# ─────────────────────────────────────────────────────────────────────────────
# Test (e): exit code propagation — 0, 1, 2, 130
# ─────────────────────────────────────────────────────────────────────────────

CB_E2="$(make_cb_root cb_e2)"
mkdir -p "$CB_E2/harnesses/claude"
make_stub "$CB_E2/harnesses/claude/dispatch.sh" 'exit 2'

actual_ec=0
"$CB_E2/codegen-build" --harness=claude --stack=phoenix \
    "test" 2>/dev/null || actual_ec=$?
check "(e) exit code 2 propagates" "2" "$actual_ec"

for ec in 0 1 130; do
    CB_E="$(make_cb_root "cb_e${ec}")"
    mkdir -p "$CB_E/harnesses/claude"
    MARKER_E="$BASE_TMP/marker_e${ec}"
    mkdir -p "$MARKER_E"
    if [[ "$ec" -eq 0 ]]; then
        make_stub "$CB_E/harnesses/claude/dispatch.sh" "$(result_ok_body)"
    else
        make_stub "$CB_E/harnesses/claude/dispatch.sh" "exit $ec"
    fi

    actual_ec=0
    "$CB_E/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_E" \
        "test prompt" 2>/dev/null ||
        actual_ec=$?

    check "(e) exit code $ec propagates" "$ec" "$actual_ec"
done

# ─────────────────────────────────────────────────────────────────────────────
# Test (a): --harness=claude → dispatch.sh execs
# `mix codegen.loop --harness=claude_code ...` (loop path)
# ─────────────────────────────────────────────────────────────────────────────
CB_A="$(make_cb_root cb_a)"
make_claude_harness "$CB_A" >/dev/null

ARGS_A="$BASE_TMP/args_a.txt"
BIN_A="$BASE_TMP/bin_a"
make_mix_stub "$BIN_A"
make_codegen_log_stub "$BIN_A"

# Real dispatch.sh execs a stubbed `mix` that never writes gate-result.json —
# plant one at the --cwd target so the post-step's fail-closed check passes.
MARKER_A="$BASE_TMP/marker_a"
mkdir -p "$MARKER_A/codegen/gate-pending"
printf '{"verdict":"clear"}\n' >"$MARKER_A/codegen/gate-pending/gate-result.json"

actual_ec=0
TARGET_ARGS_FILE="$ARGS_A" \
    PATH="$BIN_A:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_A/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_A" \
    "hello prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_A" ]]; then
    ARGS_A_CONTENT="$(cat "$ARGS_A")"
    assert_contains "(a) mix codegen.loop invoked" "$ARGS_A_CONTENT" "codegen.loop"
    assert_contains "(a) --harness=claude_code passed" "$ARGS_A_CONTENT" "--harness=claude_code"
    assert_contains "(a) --stack passed" "$ARGS_A_CONTENT" "--stack="
    assert_contains "(a) --cwd passed" "$ARGS_A_CONTENT" "--cwd="
    assert_contains "(a) prompt is forwarded" "$ARGS_A_CONTENT" "hello prompt"
else
    printf 'FAIL: (a) args file not created — mix stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 5))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (b): --harness=pi → dispatch.sh execs
# `mix codegen.loop --harness=pi ...` (loop path)
# ─────────────────────────────────────────────────────────────────────────────
CB_B="$(make_cb_root cb_b)"
make_pi_harness "$CB_B" >/dev/null

ARGS_B="$BASE_TMP/args_b.txt"
BIN_B="$BASE_TMP/bin_b"
make_mix_stub "$BIN_B"
make_codegen_log_stub "$BIN_B"

# Real dispatch.sh execs a stubbed `mix` that never writes gate-result.json —
# plant one at the --cwd target so the post-step's fail-closed check passes
# and codegen-build's pi-leg `rm -f` on --cwd cleanup never touches the live
# repo's own codegen/gate-pending/ (which is what --cwd omission used to do).
MARKER_B="$BASE_TMP/marker_b"
mkdir -p "$MARKER_B/codegen/gate-pending"
printf '{"verdict":"clear"}\n' >"$MARKER_B/codegen/gate-pending/gate-result.json"

actual_ec=0
TARGET_ARGS_FILE="$ARGS_B" \
    PATH="$BIN_B:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_B/codegen-build" --harness=pi --stack=phoenix --cwd="$MARKER_B" \
    "pi prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_B" ]]; then
    ARGS_B_CONTENT="$(cat "$ARGS_B")"
    assert_contains "(b) mix codegen.loop invoked" "$ARGS_B_CONTENT" "codegen.loop"
    assert_contains "(b) --harness=pi passed" "$ARGS_B_CONTENT" "--harness=pi"
    assert_contains "(b) --stack passed" "$ARGS_B_CONTENT" "--stack="
    assert_contains "(b) --cwd passed" "$ARGS_B_CONTENT" "--cwd="
    assert_contains "(b) prompt forwarded" "$ARGS_B_CONTENT" "pi prompt"
else
    printf 'FAIL: (b) args file not created — mix stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 5))
fi

# Live-tree-untouched: this test used to run the real pi-leg codegen-build
# with no --cwd, defaulting CWD=$PWD and rm -f'ing the live repo's
# codegen/gate-pending/{gate-result.json,cycle-state.json}. --cwd="$MARKER_B"
# above scopes the rm -f to the marker dir. run-tests.sh's whole-directory
# snapshot/compare of the live codegen/gate-pending/ (see run-tests.sh) is
# the backstop that catches any future regression of this kind.

# ─────────────────────────────────────────────────────────────────────────────
# Test (b2): --harness=pi exits non-zero when dispatch succeeds but gate verdict is missing
# ─────────────────────────────────────────────────────────────────────────────
CB_B2="$(make_cb_root cb_b2)"
mkdir -p "$CB_B2/harnesses/pi"
make_stub "$CB_B2/harnesses/pi/dispatch.sh" 'exit 0'

actual_ec=0
(
    cd "$CB_B2"
    ./codegen-build --harness=pi --stack=phoenix "pi prompt" 2>"$BASE_TMP/stderr_b2"
) || actual_ec=$?

stderr_b2="$(cat "$BASE_TMP/stderr_b2")"
check "(b2) missing gate result exits non-zero" "1" "$actual_ec"
assert_contains "(b2) stderr mentions missing build-result.json" "$stderr_b2" "build-result.json"
assert_contains "(b2) stderr is fail-closed" "$stderr_b2" "missing"

# ─────────────────────────────────────────────────────────────────────────────
# Test (b3): --harness=pi succeeds when dispatch writes a clear gate result
# ─────────────────────────────────────────────────────────────────────────────
CB_B3="$(make_cb_root cb_b3)"
mkdir -p "$CB_B3/harnesses/pi"
make_stub "$CB_B3/harnesses/pi/dispatch.sh" "$(result_ok_body)"

actual_ec=0
(
    cd "$CB_B3"
    ./codegen-build --harness=pi --stack=phoenix "pi prompt" >/dev/null 2>&1
) || actual_ec=$?
check "(b3) clear gate result exits 0" "0" "$actual_ec"

# ─────────────────────────────────────────────────────────────────────────────
# Test (f): stdout byte-identical pass-through — codegen-build → dispatch.sh
# → exec mix codegen.loop must not buffer/transform the child's stdout.
# ─────────────────────────────────────────────────────────────────────────────
FIXTURE_LINE='{"type":"result","is_error":false,"usage":{"input_tokens":42,"output_tokens":7}}'

CB_F="$(make_cb_root cb_f)"
make_claude_harness "$CB_F" >/dev/null

BIN_F="$BASE_TMP/bin_f"
mkdir -p "$BIN_F"
make_stub "$BIN_F/mix" "printf '%s\n' '${FIXTURE_LINE}'"
make_codegen_log_stub "$BIN_F"

# mix stub never writes gate-result.json — plant one at --cwd so the
# post-step's fail-closed check passes and stdout passthrough can be checked.
MARKER_F="$BASE_TMP/marker_f"
mkdir -p "$MARKER_F/codegen/gate-pending"
printf '{"verdict":"clear"}\n' >"$MARKER_F/codegen/gate-pending/gate-result.json"

ACTUAL_F_OUT=$(PATH="$BIN_F:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_F/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_F" \
    "fixture prompt" 2>/dev/null ||
    true)

ACTUAL_FIRST_LINE="$(printf '%s\n' "$ACTUAL_F_OUT" | head -1)"
check "(f) stdout byte-identical pass-through" "$FIXTURE_LINE" "$ACTUAL_FIRST_LINE"

# ─────────────────────────────────────────────────────────────────────────────
# Test (k): install-launcher self-build — $SCRIPT_DIR (cb_root) ≠ $CWD, but $CWD
# carries the codegen repo markers ⇒ integrate pre-step MUST be skipped.
# This is the case the location-based guard ($CWD == $SCRIPT_DIR) missed.
# ─────────────────────────────────────────────────────────────────────────────
CB_K="$(make_cb_root cb_k)"
make_claude_harness "$CB_K" >/dev/null
# Copy real codegen-scaffold so SCAFFOLD_CMD is executable and the integrate
# pre-step block actually runs (otherwise the guard is never reached).
link_or_copy "$CODEGEN_ROOT/codegen-scaffold" "$CB_K/codegen-scaffold"

# Marker-bearing $CWD distinct from cb_root (= $SCRIPT_DIR). Simulates running
# the INSTALLED launcher against the codegen repo root.
MARKER_CWD="$BASE_TMP/marker_cwd"
mkdir -p "$MARKER_CWD/harnesses/claude" "$MARKER_CWD/templates/generator"
touch "$MARKER_CWD/harnesses/claude/manifest.yaml" "$MARKER_CWD/templates/generator/generate.sh"

# Dispatch stub exits 0 so the build short-circuits right after the integrate pre-step.
make_stub "$CB_K/harnesses/claude/dispatch.sh" "$(result_ok_body)"

STDERR_K="$BASE_TMP/stderr_k.txt"
actual_ec=0
OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_K/codegen-build" --harness=claude --stack=phoenix \
    --cwd="$MARKER_CWD" "k prompt" 2>"$STDERR_K" >/dev/null || actual_ec=$?

STDERR_K_CONTENT="$(cat "$STDERR_K")"
assert_contains "(k) self-build skip message emitted for install-launcher cwd" "$STDERR_K_CONTENT" "self-build detected"

# Integrate must NOT have run → no AGENTS.md symlink written into marker cwd.
if [[ ! -e "$MARKER_CWD/AGENTS.md" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (k) integrate skipped — no AGENTS.md written into marker cwd\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (k) integrate ran — AGENTS.md written into marker cwd despite markers present\n'
    fail=$((fail + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Tests (p1)-(p5): --stack optional, detected from cwd markers.
# Fixtures do NOT copy codegen-scaffold into the cb_root so the integrate
# pre-step's `[[ -x "$SCAFFOLD_CMD" ]]` check is false and the block is
# skipped entirely — isolates detection from the integrate side effect.
# ─────────────────────────────────────────────────────────────────────────────

# (p1) mix.exs only → detects phoenix
CB_P1="$(make_cb_root cb_p1)"
mkdir -p "$CB_P1/harnesses/claude"
make_stub "$CB_P1/harnesses/claude/dispatch.sh" "$(result_ok_body)"
MARKER_P1="$BASE_TMP/marker_p1"
mkdir -p "$MARKER_P1"
touch "$MARKER_P1/mix.exs"

actual_ec=0
stderr_p1=$("$CB_P1/codegen-build" --harness=claude --cwd="$MARKER_P1" \
    "p1 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p1) mix.exs-only detects phoenix: exit 0" "0" "$actual_ec"
assert_contains "(p1) stderr reports detected stack=phoenix" "$stderr_p1" "detected stack=phoenix from cwd markers"

# (p2) vite.config.js only → detects static
CB_P2="$(make_cb_root cb_p2)"
mkdir -p "$CB_P2/harnesses/claude"
make_stub "$CB_P2/harnesses/claude/dispatch.sh" "$(result_ok_body)"
MARKER_P2="$BASE_TMP/marker_p2"
mkdir -p "$MARKER_P2"
touch "$MARKER_P2/vite.config.js"

actual_ec=0
stderr_p2=$("$CB_P2/codegen-build" --harness=claude --cwd="$MARKER_P2" \
    "p2 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p2) vite.config.js-only detects static: exit 0" "0" "$actual_ec"
assert_contains "(p2) stderr reports detected stack=static" "$stderr_p2" "detected stack=static from cwd markers"

# (p3) both mix.exs and vite.config.js → ambiguous, exit 2
CB_P3="$(make_cb_root cb_p3)"
mkdir -p "$CB_P3/harnesses/claude"
make_stub "$CB_P3/harnesses/claude/dispatch.sh" 'exit 0'
MARKER_P3="$BASE_TMP/marker_p3"
mkdir -p "$MARKER_P3"
touch "$MARKER_P3/mix.exs" "$MARKER_P3/vite.config.js"

actual_ec=0
stderr_p3=$("$CB_P3/codegen-build" --harness=claude --cwd="$MARKER_P3" \
    "p3 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p3) both markers present: ambiguous exit 2" "2" "$actual_ec"
assert_contains "(p3) stderr mentions ambiguous" "$stderr_p3" "ambiguous"
assert_contains "(p3) stderr names both markers" "$stderr_p3" "mix.exs and vite.config.js"

# (p4) neither marker → cannot detect, exit 2
CB_P4="$(make_cb_root cb_p4)"
mkdir -p "$CB_P4/harnesses/claude"
make_stub "$CB_P4/harnesses/claude/dispatch.sh" 'exit 0'
MARKER_P4="$BASE_TMP/marker_p4"
mkdir -p "$MARKER_P4"

actual_ec=0
stderr_p4=$("$CB_P4/codegen-build" --harness=claude --cwd="$MARKER_P4" \
    "p4 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p4) no markers: cannot detect exit 2" "2" "$actual_ec"
assert_contains "(p4) stderr mentions cannot detect stack" "$stderr_p4" "cannot detect stack"

# (p5) self-build markers present → detects phoenix (case-2 precedence)
CB_P5="$(make_cb_root cb_p5)"
mkdir -p "$CB_P5/harnesses/claude"
make_stub "$CB_P5/harnesses/claude/dispatch.sh" "$(result_ok_body)"
MARKER_P5="$BASE_TMP/marker_p5"
mkdir -p "$MARKER_P5/harnesses/claude" "$MARKER_P5/templates/generator"
touch "$MARKER_P5/harnesses/claude/manifest.yaml" "$MARKER_P5/templates/generator/generate.sh"

actual_ec=0
stderr_p5=$("$CB_P5/codegen-build" --harness=claude --cwd="$MARKER_P5" \
    "p5 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p5) self-build markers detect phoenix: exit 0" "0" "$actual_ec"
assert_contains "(p5) stderr reports detected stack=phoenix" "$stderr_p5" "detected stack=phoenix"

# ─────────────────────────────────────────────────────────────────────────────
# Tests (q1)-(q4): schema-staleness preflight (codegen/manifest.yaml).
# cb_root fixtures do NOT ship shared/scaffold/SCHEMA_VERSION by default
# (make_cb_root only copies codegen-build itself) — cases needing a version
# plant $CB_X/shared/scaffold/SCHEMA_VERSION themselves.
# ─────────────────────────────────────────────────────────────────────────────

# (q1) manifest absent → build proceeds (preflight skipped, no refuse message)
CB_Q1="$(make_cb_root cb_q1)"
mkdir -p "$CB_Q1/harnesses/claude" "$CB_Q1/shared/scaffold"
make_stub "$CB_Q1/harnesses/claude/dispatch.sh" "$(result_ok_body)"
printf '1\n' >"$CB_Q1/shared/scaffold/SCHEMA_VERSION"
MARKER_Q1="$BASE_TMP/marker_q1"
mkdir -p "$MARKER_Q1"

actual_ec=0
stderr_q1=$("$CB_Q1/codegen-build" --harness=claude --stack=static --cwd="$MARKER_Q1" \
    "q1 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q1) manifest absent: proceeds exit 0" "0" "$actual_ec"
q1_refused=$(printf '%s' "$stderr_q1" | grep -c "app wired at scaffold schema" || true)
check "(q1) no refuse message when manifest absent" "0" "$q1_refused"

# (q2) stamped version equals current → proceeds
CB_Q2="$(make_cb_root cb_q2)"
mkdir -p "$CB_Q2/harnesses/claude" "$CB_Q2/shared/scaffold"
make_stub "$CB_Q2/harnesses/claude/dispatch.sh" "$(result_ok_body)"
printf '1\n' >"$CB_Q2/shared/scaffold/SCHEMA_VERSION"
MARKER_Q2="$BASE_TMP/marker_q2"
mkdir -p "$MARKER_Q2/codegen"
printf 'scaffold_schema_version: 1\nscaffolded_from_sha: abc123\nscaffolded_at: 2026-01-01T00:00:00Z\n' \
    >"$MARKER_Q2/codegen/manifest.yaml"

actual_ec=0
stderr_q2=$("$CB_Q2/codegen-build" --harness=claude --stack=static --cwd="$MARKER_Q2" \
    "q2 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q2) stamped version equals current: proceeds exit 0" "0" "$actual_ec"
q2_refused=$(printf '%s' "$stderr_q2" | grep -c "app wired at scaffold schema" || true)
check "(q2) no refuse message when versions equal" "0" "$q2_refused"

# (q3) stamped version behind current → refuse exit 2 + remediation message
# RED-then-GREEN: this fixture is deliberately behind (0 < 1); confirm the
# refusal fires before trusting the mitigation is load-bearing.
CB_Q3="$(make_cb_root cb_q3)"
mkdir -p "$CB_Q3/harnesses/claude" "$CB_Q3/shared/scaffold"
make_stub "$CB_Q3/harnesses/claude/dispatch.sh" 'exit 0'
printf '1\n' >"$CB_Q3/shared/scaffold/SCHEMA_VERSION"
MARKER_Q3="$BASE_TMP/marker_q3"
mkdir -p "$MARKER_Q3/codegen"
printf 'scaffold_schema_version: 0\nscaffolded_from_sha: abc123\nscaffolded_at: 2026-01-01T00:00:00Z\n' \
    >"$MARKER_Q3/codegen/manifest.yaml"

actual_ec=0
stderr_q3=$("$CB_Q3/codegen-build" --harness=claude --stack=static --cwd="$MARKER_Q3" \
    "q3 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q3) stamped version behind current: refuse exit 2" "2" "$actual_ec"
assert_contains "(q3) stderr names remediation command" "$stderr_q3" "codegen-scaffold integrate"
assert_contains "(q3) stderr reports stamped v0" "$stderr_q3" "v0"
assert_contains "(q3) stderr reports current v1" "$stderr_q3" "v1"

# (q4) self-build markers present + behind manifest → preflight skipped, proceeds
CB_Q4="$(make_cb_root cb_q4)"
mkdir -p "$CB_Q4/harnesses/claude" "$CB_Q4/shared/scaffold"
make_stub "$CB_Q4/harnesses/claude/dispatch.sh" "$(result_ok_body)"
printf '1\n' >"$CB_Q4/shared/scaffold/SCHEMA_VERSION"
MARKER_Q4="$BASE_TMP/marker_q4"
mkdir -p "$MARKER_Q4/codegen" "$MARKER_Q4/harnesses/claude" "$MARKER_Q4/templates/generator"
touch "$MARKER_Q4/harnesses/claude/manifest.yaml" "$MARKER_Q4/templates/generator/generate.sh"
printf 'scaffold_schema_version: 0\nscaffolded_from_sha: abc123\nscaffolded_at: 2026-01-01T00:00:00Z\n' \
    >"$MARKER_Q4/codegen/manifest.yaml"

actual_ec=0
stderr_q4=$("$CB_Q4/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_Q4" \
    "q4 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q4) self-build markers present: preflight skipped, proceeds exit 0" "0" "$actual_ec"
q4_refused=$(printf '%s' "$stderr_q4" | grep -c "app wired at scaffold schema" || true)
check "(q4) no refuse message on self-build even with behind manifest" "0" "$q4_refused"

# ─────────────────────────────────────────────────────────────────────────────
# Test (m): claude dispatch exits 0 with NO gate-result.json → fail closed.
# Proves the fabricated-clear-verdict synth block is gone: before that fix
# this case would fabricate a clear verdict and exit 0.
# ─────────────────────────────────────────────────────────────────────────────
CB_M="$(make_cb_root cb_m)"
mkdir -p "$CB_M/harnesses/claude"
make_stub "$CB_M/harnesses/claude/dispatch.sh" 'exit 0'
MARKER_M="$BASE_TMP/marker_m"
mkdir -p "$MARKER_M"

actual_ec=0
stderr_m=$("$CB_M/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_M" \
    "m prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(m) missing build-result.json fails closed" "1" "$actual_ec"
assert_contains "(m) stderr mentions missing build-result.json" "$stderr_m" "missing build-result.json"
[[ ! -f "$MARKER_M/codegen/gate-pending/gate-result.json" ]] &&
    {
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (m) no gate-result.json fabricated\n'
        pass=$((pass + 1))
    } ||
    {
        printf 'FAIL: (m) a gate-result.json was fabricated despite no gate having run\n'
        fail=$((fail + 1))
    }

# ─────────────────────────────────────────────────────────────────────────────
# Test (m2): wrapper result authority binds invocation, exact slug, HEAD, status,
# and gate verdict. Each corrupt result must fail closed after dispatch exits 0.
# ─────────────────────────────────────────────────────────────────────────────
for result_case in wrong_slug wrong_invocation wrong_head non_success non_clear; do
    CB_M2="$(make_cb_root "cb_m2_${result_case}")"
    mkdir -p "$CB_M2/harnesses/claude"
    make_stub "$CB_M2/harnesses/claude/dispatch.sh" "$(result_ok_body)"
    MARKER_M2="$BASE_TMP/marker_m2_${result_case}"
    mkdir -p "$MARKER_M2/codegen/pitches/ready"
    printf '%s\n' '---' 'status: SHAPED' '---' '# expected-slug' >"$MARKER_M2/codegen/pitches/ready/expected-slug.md"

    case "$result_case" in
    wrong_slug) result_env=(RESULT_SLUG=other-slug) ;;
    wrong_invocation) result_env=(RESULT_INVOCATION_ID=stale-invocation) ;;
    wrong_head) result_env=(RESULT_HEAD=0000000000000000000000000000000000000000) ;;
    non_success) result_env=(RESULT_STATUS=failed) ;;
    non_clear) result_env=(RESULT_VERDICT=failed) ;;
    esac

    actual_ec=0
    env "${result_env[@]}" "$CB_M2/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_M2" \
        "@$MARKER_M2/codegen/pitches/ready/expected-slug.md" >/dev/null 2>&1 || actual_ec=$?
    check "(m2) ${result_case} result evidence fails closed" "1" "$actual_ec"
done

# ─────────────────────────────────────────────────────────────────────────────
# Test (g): codegen-build must never write into $PWD when --cwd points
# elsewhere — no gate-pending state leaks into the invoking shell's directory.
# ─────────────────────────────────────────────────────────────────────────────
CB_G="$(make_cb_root cb_g)"
mkdir -p "$CB_G/harnesses/claude"
make_stub "$CB_G/harnesses/claude/dispatch.sh" "$(result_ok_body)"
MARKER_G="$BASE_TMP/marker_g"
mkdir -p "$MARKER_G"
SCRATCH_G="$BASE_TMP/scratch_g"
mkdir -p "$SCRATCH_G"

actual_ec=0
(
    cd "$SCRATCH_G"
    "$CB_G/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_G" \
        "g prompt" >/dev/null 2>&1
) || actual_ec=$?
check "(g) build with --cwd elsewhere exits 0" "0" "$actual_ec"
if [[ ! -d "$SCRATCH_G/codegen" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (g) no codegen/ dir leaked into $PWD\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (g) codegen/ dir leaked into $PWD (%s)\n' "$SCRATCH_G"
    fail=$((fail + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (pa1): --print-argv on claude leg — exits 0, prints codegen.loop argv,
# never invokes the stubbed mix binary (zero spend).
# ─────────────────────────────────────────────────────────────────────────────
CB_PA1="$(make_cb_root cb_pa1)"
make_claude_harness "$CB_PA1" >/dev/null

ARGS_PA1="$BASE_TMP/args_pa1.txt"
rm -f "$ARGS_PA1"
BIN_PA1="$BASE_TMP/bin_pa1"
make_mix_stub "$BIN_PA1"
make_codegen_log_stub "$BIN_PA1"

MARKER_PA1="$BASE_TMP/marker_pa1"
mkdir -p "$MARKER_PA1"

actual_ec=0
OUT_PA1=$(TARGET_ARGS_FILE="$ARGS_PA1" \
    PATH="$BIN_PA1:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_PA1/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_PA1" \
    --print-argv "pa1 prompt" 2>/dev/null) || actual_ec=$?

check "(pa1) --print-argv exits 0" "0" "$actual_ec"
assert_contains "(pa1) output mentions codegen.loop" "$OUT_PA1" "codegen.loop"
assert_contains "(pa1) output mentions --harness=claude_code" "$OUT_PA1" "--harness=claude_code"
assert_contains "(pa1) output mentions --stack=phoenix" "$OUT_PA1" "--stack=phoenix"
assert_contains "(pa1) output mentions prompt" "$OUT_PA1" "pa1 prompt"
if [[ -f "$ARGS_PA1" ]]; then
    printf 'FAIL: (pa1) mix stub was invoked despite --print-argv (zero-spend violated)\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (pa1) mix stub never invoked\n'
    pass=$((pass + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (pa2): --print-argv on pi leg — same, --harness=pi.
# ─────────────────────────────────────────────────────────────────────────────
CB_PA2="$(make_cb_root cb_pa2)"
make_pi_harness "$CB_PA2" >/dev/null

ARGS_PA2="$BASE_TMP/args_pa2.txt"
rm -f "$ARGS_PA2"
BIN_PA2="$BASE_TMP/bin_pa2"
make_mix_stub "$BIN_PA2"
make_codegen_log_stub "$BIN_PA2"

actual_ec=0
OUT_PA2=$(TARGET_ARGS_FILE="$ARGS_PA2" \
    PATH="$BIN_PA2:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_PA2/codegen-build" --harness=pi --stack=phoenix \
    --print-argv "pa2 prompt" 2>/dev/null) || actual_ec=$?

check "(pa2) --print-argv exits 0 on pi leg" "0" "$actual_ec"
assert_contains "(pa2) output mentions codegen.loop" "$OUT_PA2" "codegen.loop"
assert_contains "(pa2) output mentions --harness=pi" "$OUT_PA2" "--harness=pi"
if [[ -f "$ARGS_PA2" ]]; then
    printf 'FAIL: (pa2) mix stub was invoked despite --print-argv (zero-spend violated)\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (pa2) mix stub never invoked\n'
    pass=$((pass + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (pa3): --print-argv performs zero mutation — integrate pre-step must
# be skipped (no AGENTS.md / codegen/manifest.yaml written into --cwd).
# ─────────────────────────────────────────────────────────────────────────────
CB_PA3="$(make_cb_root cb_pa3)"
make_claude_harness "$CB_PA3" >/dev/null
link_or_copy "$CODEGEN_ROOT/codegen-scaffold" "$CB_PA3/codegen-scaffold"

BIN_PA3="$BASE_TMP/bin_pa3"
make_mix_stub "$BIN_PA3"
make_codegen_log_stub "$BIN_PA3"

MARKER_PA3="$BASE_TMP/marker_pa3"
mkdir -p "$MARKER_PA3"

actual_ec=0
PATH="$BIN_PA3:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_PA3/codegen-build" --harness=claude --stack=static --cwd="$MARKER_PA3" \
    --print-argv "pa3 prompt" >/dev/null 2>/dev/null || actual_ec=$?

check "(pa3) --print-argv exits 0" "0" "$actual_ec"
if [[ ! -e "$MARKER_PA3/AGENTS.md" ]] && [[ ! -e "$MARKER_PA3/codegen" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (pa3) integrate pre-step skipped — no mutation of --cwd\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (pa3) --print-argv mutated --cwd (AGENTS.md or codegen/ written)\n'
    fail=$((fail + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (b1) dry-run honesty: --max-budget-usd threads through
# CODEGEN_BUILD_MAX_BUDGET_USD -> --print-argv output MUST contain
# --max-budget-usd=<n>. RED-then-GREEN: this is the assertion that never
# existed before the flag was actually wired (it only pinned the flag's mere
# PARSE-time presence, never its effect) — confirm it would have failed
# against the pre-fix dispatch.sh (blind $@ splat, never threaded by name).
# ─────────────────────────────────────────────────────────────────────────────
CB_B1="$(make_cb_root cb_b1)"
make_claude_harness "$CB_B1" >/dev/null

BIN_B1="$BASE_TMP/bin_b1"
make_mix_stub "$BIN_B1"
make_codegen_log_stub "$BIN_B1"

MARKER_B1="$BASE_TMP/marker_b1"
mkdir -p "$MARKER_B1"

actual_ec=0
OUT_B1=$(PATH="$BIN_B1:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_B1/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_B1" \
    --max-budget-usd=20 --print-argv "b1 prompt" 2>/dev/null) || actual_ec=$?

check "(b1) --print-argv with --max-budget-usd exits 0" "0" "$actual_ec"
assert_contains "(b1) print-argv output contains --max-budget-usd=20" "$OUT_B1" "--max-budget-usd=20"
assert_contains "(b1) output still mentions codegen.loop" "$OUT_B1" "codegen.loop"

# ─────────────────────────────────────────────────────────────────────────────
# Test (b2-pi) same dry-run honesty check on the pi leg.
# ─────────────────────────────────────────────────────────────────────────────
CB_B1PI="$(make_cb_root cb_b1pi)"
make_pi_harness "$CB_B1PI" >/dev/null

BIN_B1PI="$BASE_TMP/bin_b1pi"
make_mix_stub "$BIN_B1PI"
make_codegen_log_stub "$BIN_B1PI"

actual_ec=0
OUT_B1PI=$(PATH="$BIN_B1PI:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    "$CB_B1PI/codegen-build" --harness=pi --stack=phoenix \
    --max-budget-usd=7.50 --print-argv "b1pi prompt" 2>/dev/null) || actual_ec=$?

check "(b2-pi) --print-argv with --max-budget-usd exits 0 on pi leg" "0" "$actual_ec"
assert_contains "(b2-pi) print-argv output contains --max-budget-usd=7.50" "$OUT_B1PI" "--max-budget-usd=7.50"

# ─────────────────────────────────────────────────────────────────────────────
# Test (b3) non-adoption: zero occurrences of --max-budget-usd across
# Makefile, codegen-*, harnesses/**, .env* outside the parser (codegen-build
# itself), the two dispatch.sh scripts, docs, and this test file. Codegen
# itself never passes the flag — the operator mandate from the pitch: wire
# the mechanism, never adopt it here.
# ─────────────────────────────────────────────────────────────────────────────
nonadopt_scan() {
    grep -rl -- '--max-budget-usd' \
        "$CODEGEN_ROOT/Makefile" \
        "$CODEGEN_ROOT"/codegen-* \
        "$CODEGEN_ROOT/harnesses" \
        "$CODEGEN_ROOT"/.env* \
        2>/dev/null || true
}

# Each grep -v stage legitimately exits 1 when it filters out every line
# (nothing left to select) — with `set -o pipefail` that mid-pipe non-zero
# would otherwise abort this whole script under `set -e`. Wrap the full
# pipeline in a `|| true` subshell rather than the individual stages so the
# real filtering logic stays a plain, readable pipe.
NONADOPT_HITS=$(
    {
        nonadopt_scan |
            grep -vF -- "$CODEGEN_ROOT/codegen-build" |
            grep -vF -- "$CODEGEN_ROOT/harnesses/claude/dispatch.sh" |
            grep -vF -- "$CODEGEN_ROOT/harnesses/pi/dispatch.sh" |
            grep -vF -- "$CODEGEN_ROOT/harnesses/claude/hooks/fixtures/codegen-build-flags.txt" |
            grep -vF -- "$CODEGEN_ROOT/harnesses/claude/hooks/codegen-build_test.sh" ||
            true
    } | wc -l | tr -d ' '
)
check "(b3) codegen never adopts --max-budget-usd itself (0 stray occurrences)" "0" "$NONADOPT_HITS"

# ─────────────────────────────────────────────────────────────────────────────
# Test (u): usage<->parse parity — every parsed --flag appears in usage
# string, and every usage-mentioned --flag is parsed in the case block.
# ─────────────────────────────────────────────────────────────────────────────
CB_USAGE_LINE="$(grep -m1 'printf .Usage: codegen-build' "$CODEGEN_BUILD" || true)"

CB_PARSED_FLAGS="$(sed -n '/^while \[\[ \$# -gt 0 \]\]; do/,/^done/p' "$CODEGEN_BUILD" | grep -oE -- '--[a-zA-Z-]+' | grep -vxF -- '--' | sort -u)"

CB_MISSING_FROM_USAGE=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$CB_USAGE_LINE" != *"$flag"* ]]; then
        printf 'FAIL: (u) flag %s parsed but missing from usage string\n' "$flag"
        CB_MISSING_FROM_USAGE=$((CB_MISSING_FROM_USAGE + 1))
    fi
done <<<"$CB_PARSED_FLAGS"
check "(u) every parsed flag appears in usage string" "0" "$CB_MISSING_FROM_USAGE"

CB_USAGE_FLAGS="$(printf '%s' "$CB_USAGE_LINE" | grep -oE -- '--[a-zA-Z-]+' | sort -u)"
CB_MISSING_FROM_PARSE=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$CB_PARSED_FLAGS" != *"$flag"* ]]; then
        printf 'FAIL: (u) flag %s in usage string but not parsed\n' "$flag"
        CB_MISSING_FROM_PARSE=$((CB_MISSING_FROM_PARSE + 1))
    fi
done <<<"$CB_USAGE_FLAGS"
check "(u) every usage-mentioned flag is parsed" "0" "$CB_MISSING_FROM_PARSE"

# ─────────────────────────────────────────────────────────────────────────────
# Test (snap): public flag surface snapshot — codegen-build's parsed flags
# must equal the committed fixture, in both directions. This is the assertion
# usage<->parse parity CANNOT give: deleting a flag from both the parser and
# the usage string keeps parity green, but this snapshot goes RED.
# ─────────────────────────────────────────────────────────────────────────────
CB_FIXTURE="$HOOKS_DIR/fixtures/codegen-build-flags.txt"
CB_FIXTURE_FLAGS="$(grep -v '^#' "$CB_FIXTURE" | grep -v '^[[:space:]]*$' | sort -u)"

CB_SNAP_ADDED=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$CB_FIXTURE_FLAGS" != *"$flag"* ]]; then
        printf 'FAIL: (snap) flag %s parsed but NOT in committed fixture (surface grew — update the fixture deliberately)\n' "$flag"
        CB_SNAP_ADDED=$((CB_SNAP_ADDED + 1))
    fi
done <<<"$CB_PARSED_FLAGS"
check "(snap) no parsed flag missing from fixture" "0" "$CB_SNAP_ADDED"

CB_SNAP_REMOVED=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$CB_PARSED_FLAGS" != *"$flag"* ]]; then
        printf 'FAIL: (snap) flag %s in committed fixture but NOT parsed (surface shrank — a flag was deleted!)\n' "$flag"
        CB_SNAP_REMOVED=$((CB_SNAP_REMOVED + 1))
    fi
done <<<"$CB_FIXTURE_FLAGS"
check "(snap) no fixture flag missing from parser" "0" "$CB_SNAP_REMOVED"

# ─────────────────────────────────────────────────────────────────────────────
# Test (d): dead-export absence — CODEGEN_BUILD_MODEL/EFFORT are advisory-only
# and must never be exported. --model/--effort stay parsed (see (u)/(snap))
# but must not leak into a CODEGEN_BUILD_* env var nothing reads.
# ─────────────────────────────────────────────────────────────────────────────
CB_DEAD_EXPORTS=$(grep -cE 'export CODEGEN_BUILD_(MODEL|EFFORT)=' "$CODEGEN_BUILD" || true)
check "(d) CODEGEN_BUILD_MODEL/EFFORT never exported" "0" "$CB_DEAD_EXPORTS"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
