#!/usr/bin/env bash
# codegen-build_test.sh — unit tests for codegen-build, dispatch.sh (claude + pi).
#
# Tests:
#  (a) --harness=claude exec's claude dispatch with correct argv including tools
#  (b) --harness=pi exec's pi dispatch with correct argv
#  (c) missing --harness exits 2 with usage on stderr
#  (d) missing prompt exits 2
#  (e) exit codes 0/1/2/130 propagate from stub
#  (f) stdout passes through fixture stream-json byte-identical

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
CODEGEN_BUILD="$CODEGEN_ROOT/codegen-build"
REAL_CLAUDE_HARNESS="$CODEGEN_ROOT/harnesses/claude"
REAL_PI_HARNESS="$CODEGEN_ROOT/harnesses/pi"

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

    if printf '%s' "$haystack" | grep -Fq -- "$needle" 2>/dev/null ||
        printf '%s' "$haystack" | fgrep -q "$needle" 2>/dev/null; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        # fallback: string comparison
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
# The real codegen-build uses SCRIPT_DIR=$(dirname $0) to find harnesses/.
# Strategy: copy codegen-build to a dir, create harnesses/ subdir there.
make_cb_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir"
    cp "$CODEGEN_BUILD" "$dir/codegen-build"
    chmod +x "$dir/codegen-build"
    echo "$dir"
}

make_claude_harness() {
    local cb_root="$1"
    local harness_dir="$cb_root/harnesses/claude"
    mkdir -p "$harness_dir"
    cp "$REAL_CLAUDE_HARNESS/dispatch.sh" "$harness_dir/dispatch.sh"
    # Tools file: copy real one
    cp "$REAL_CLAUDE_HARNESS/build-tools.txt" "$harness_dir/build-tools.txt"
    cp "$REAL_CLAUDE_HARNESS/claude-build-system-prompt.txt" "$harness_dir/claude-build-system-prompt.txt"
    echo "$harness_dir"
}

make_pi_harness() {
    local cb_root="$1"
    local harness_dir="$cb_root/harnesses/pi"
    mkdir -p "$harness_dir"
    cp "$REAL_PI_HARNESS/dispatch.sh" "$harness_dir/dispatch.sh"
    # pi-build-system-prompt.txt is read by dispatch.sh for headless builds; stub it so the test has a valid harness dir
    printf 'stub system prompt\n' >"$harness_dir/pi-build-system-prompt.txt"
    echo "$harness_dir"
}

make_stub() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
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
# Test (d): missing prompt in non-interactive mode → exit 2
# ─────────────────────────────────────────────────────────────────────────────
CB_D="$(make_cb_root cb_d)"
make_claude_harness "$CB_D" >/dev/null

actual_exit=0
"$CB_D/codegen-build" --harness=claude --stack=phoenix --non-interactive 2>/dev/null || actual_exit=$?
check "(d) missing prompt in non-interactive exits 2" "2" "$actual_exit"

# ─────────────────────────────────────────────────────────────────────────────
# Test (e): exit code propagation — 0, 1, 2, 130
# ─────────────────────────────────────────────────────────────────────────────

# For exit 2 — just use a dispatch stub that exits 2 directly
CB_E2="$(make_cb_root cb_e2)"
mkdir -p "$CB_E2/harnesses/claude"
make_stub "$CB_E2/harnesses/claude/dispatch.sh" 'exit 2'

actual_ec=0
"$CB_E2/codegen-build" --harness=claude --stack=phoenix --non-interactive \
    "test" 2>/dev/null || actual_ec=$?
check "(e) exit code 2 propagates" "2" "$actual_ec"

# For exit 0, 1, 130 — use dispatch stubs (not real dispatch, no real claude needed)
for ec in 0 1 130; do
    CB_E="$(make_cb_root "cb_e${ec}")"
    mkdir -p "$CB_E/harnesses/claude"
    make_stub "$CB_E/harnesses/claude/dispatch.sh" "exit $ec"

    actual_ec=0
    "$CB_E/codegen-build" --harness=claude --stack=phoenix --non-interactive \
        "test prompt" 2>/dev/null ||
        actual_ec=$?

    check "(e) exit code $ec propagates" "$ec" "$actual_ec"
done

# ─────────────────────────────────────────────────────────────────────────────
# Test (a): --harness=claude → dispatch.sh with correct argv (--tools from build-tools.txt)
# ─────────────────────────────────────────────────────────────────────────────
CB_A="$(make_cb_root cb_a)"
make_claude_harness "$CB_A" >/dev/null

ARGS_A="$BASE_TMP/args_a.txt"
CLAUDE_A_DIR="$BASE_TMP/bin_a"
mkdir -p "$CLAUDE_A_DIR"

make_stub "$CLAUDE_A_DIR/claude" "printf '%s\n' \"\$@\" > '$ARGS_A'; printf '{\"type\":\"result\"}\n'"

actual_ec=0
PATH="$CLAUDE_A_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_A/codegen-build" --harness=claude --stack=phoenix --non-interactive \
    "hello prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_A" ]]; then
    ARGS_A_CONTENT="$(cat "$ARGS_A")"
    assert_contains "(a) --tools flag present" "$ARGS_A_CONTENT" "--tools"
    assert_contains "(a) tools list contains Agent" "$ARGS_A_CONTENT" "Agent"
    assert_contains "(a) --print flag present (non-interactive)" "$ARGS_A_CONTENT" "--print"
    assert_contains "(a) --model present" "$ARGS_A_CONTENT" "--model"
    assert_contains "(a) --output-format stream-json" "$ARGS_A_CONTENT" "stream-json"
    assert_contains "(a) --dangerously-skip-permissions" "$ARGS_A_CONTENT" "--dangerously-skip-permissions"
    assert_contains "(a) prompt is forwarded" "$ARGS_A_CONTENT" "hello prompt"
    assert_contains "(a) --system-prompt present (non-interactive)" "$ARGS_A_CONTENT" "--system-prompt"
    assert_contains "(a) --setting-sources user,project,local in non-interactive" "$ARGS_A_CONTENT" "user,project,local"
else
    printf 'FAIL: (a) args file not created — claude stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 8))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (b): --harness=pi → dispatch.sh with correct argv
# ─────────────────────────────────────────────────────────────────────────────
CB_B="$(make_cb_root cb_b)"
make_pi_harness "$CB_B" >/dev/null

ARGS_B="$BASE_TMP/args_b.txt"
PI_B_DIR="$BASE_TMP/bin_b"
mkdir -p "$PI_B_DIR"
make_stub "$PI_B_DIR/pi" "printf '%s\n' \"\$@\" > '$ARGS_B'"

actual_ec=0
PATH="$PI_B_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_B/codegen-build" --harness=pi --stack=phoenix --non-interactive \
    "pi prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_B" ]]; then
    ARGS_B_CONTENT="$(cat "$ARGS_B")"
    assert_contains "(b) --mode" "$ARGS_B_CONTENT" "--mode"
    assert_contains "(b) json" "$ARGS_B_CONTENT" "json"
    assert_contains "(b) --no-session" "$ARGS_B_CONTENT" "--no-session"
    assert_contains "(b) --provider openai-codex" "$ARGS_B_CONTENT" "openai-codex"
    assert_contains "(b) -p flag (non-interactive)" "$ARGS_B_CONTENT" "-p"
    assert_contains "(b) prompt forwarded" "$ARGS_B_CONTENT" "pi prompt"
else
    printf 'FAIL: (b) args file not created — pi stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 6))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (f): stdout byte-identical pass-through
# ─────────────────────────────────────────────────────────────────────────────
FIXTURE_LINE='{"type":"result","is_error":false,"usage":{"input_tokens":42,"output_tokens":7}}'

CB_F="$(make_cb_root cb_f)"
make_claude_harness "$CB_F" >/dev/null

CLAUDE_F_DIR="$BASE_TMP/bin_f"
mkdir -p "$CLAUDE_F_DIR"
make_stub "$CLAUDE_F_DIR/claude" "printf '%s\n' '${FIXTURE_LINE}'"

ACTUAL_F_OUT=$(PATH="$CLAUDE_F_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_F/codegen-build" --harness=claude --stack=phoenix --non-interactive \
    "fixture prompt" 2>/dev/null ||
    true)

ACTUAL_FIRST_LINE="$(printf '%s\n' "$ACTUAL_F_OUT" | head -1)"
check "(f) stdout byte-identical pass-through" "$FIXTURE_LINE" "$ACTUAL_FIRST_LINE"

# ─────────────────────────────────────────────────────────────────────────────
# Test (g): interactive mode — non-interactive flags must NOT be passed
# ─────────────────────────────────────────────────────────────────────────────
CB_G="$(make_cb_root cb_g)"
make_claude_harness "$CB_G" >/dev/null

ARGS_G="$BASE_TMP/args_g.txt"
CLAUDE_G_DIR="$BASE_TMP/bin_g"
mkdir -p "$CLAUDE_G_DIR"
make_stub "$CLAUDE_G_DIR/claude" "printf '%s\n' \"\$@\" > '$ARGS_G'"

actual_ec=0
# Explicitly unset NON_INTERACTIVE — simulate interactive call with a prompt
CODEGEN_BUILD_NON_INTERACTIVE="" \
    PATH="$CLAUDE_G_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_G/codegen-build" --harness=claude --stack=phoenix \
    "interactive prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_G" ]]; then
    ARGS_G_CONTENT="$(cat "$ARGS_G")"
    # Non-interactive flags must be absent in interactive mode
    if [[ "$ARGS_G_CONTENT" != *"--no-session-persistence"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (g) --no-session-persistence absent in interactive mode\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (g) --no-session-persistence present in interactive mode\n  got: %s\n' "${ARGS_G_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
    if [[ "$ARGS_G_CONTENT" != *"--disable-slash-commands"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (g) --disable-slash-commands absent in interactive mode\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (g) --disable-slash-commands present in interactive mode\n  got: %s\n' "${ARGS_G_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
    if [[ "$ARGS_G_CONTENT" != *"--print"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (g) --print absent in interactive mode\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (g) --print present in interactive mode\n  got: %s\n' "${ARGS_G_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
    assert_contains "(g) prompt forwarded in interactive mode" "$ARGS_G_CONTENT" "interactive prompt"
    assert_contains "(g) --system-prompt present in interactive mode" "$ARGS_G_CONTENT" "--system-prompt"
    assert_contains "(g) --dangerously-skip-permissions present in interactive mode" "$ARGS_G_CONTENT" "--dangerously-skip-permissions"
else
    printf 'FAIL: (g) args file not created — claude stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 6))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (i): --system-prompt and --dangerously-skip-permissions in BOTH modes;
#           print-family flags in non-interactive only
# ─────────────────────────────────────────────────────────────────────────────
CB_I="$(make_cb_root cb_i)"
make_claude_harness "$CB_I" >/dev/null

ARGS_I_NI="$BASE_TMP/args_i_ni.txt"
ARGS_I_INT="$BASE_TMP/args_i_int.txt"
CLAUDE_I_DIR="$BASE_TMP/bin_i"
mkdir -p "$CLAUDE_I_DIR"

# Stub writes its args to a file passed via env var TARGET_ARGS_FILE
make_stub "$CLAUDE_I_DIR/claude" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'

# Non-interactive run
actual_ec=0
TARGET_ARGS_FILE="$ARGS_I_NI" \
    PATH="$CLAUDE_I_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_I/codegen-build" --harness=claude --stack=phoenix --non-interactive \
    "test prompt i" 2>/dev/null ||
    actual_ec=$?

# Interactive run
actual_ec=0
TARGET_ARGS_FILE="$ARGS_I_INT" \
    CODEGEN_BUILD_NON_INTERACTIVE="" \
    PATH="$CLAUDE_I_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_I/codegen-build" --harness=claude --stack=phoenix \
    "test prompt i" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_I_NI" && -f "$ARGS_I_INT" ]]; then
    ARGS_I_NI_CONTENT="$(cat "$ARGS_I_NI")"
    ARGS_I_INT_CONTENT="$(cat "$ARGS_I_INT")"

    # Both modes: --system-prompt present
    assert_contains "(i) --system-prompt in non-interactive" "$ARGS_I_NI_CONTENT" "--system-prompt"
    assert_contains "(i) --system-prompt in interactive" "$ARGS_I_INT_CONTENT" "--system-prompt"

    # Both modes: --dangerously-skip-permissions present
    assert_contains "(i) --dangerously-skip-permissions in non-interactive" "$ARGS_I_NI_CONTENT" "--dangerously-skip-permissions"
    assert_contains "(i) --dangerously-skip-permissions in interactive" "$ARGS_I_INT_CONTENT" "--dangerously-skip-permissions"

    # Print-family: present in non-interactive, absent in interactive
    assert_contains "(i) --print in non-interactive" "$ARGS_I_NI_CONTENT" "--print"
    assert_contains "(i) --no-session-persistence in non-interactive" "$ARGS_I_NI_CONTENT" "--no-session-persistence"
    assert_contains "(i) --disable-slash-commands in non-interactive" "$ARGS_I_NI_CONTENT" "--disable-slash-commands"

    # setting-sources: user,project,local in non-interactive; absent in interactive
    assert_contains "(i) --setting-sources user,project,local in non-interactive" "$ARGS_I_NI_CONTENT" "user,project,local"

    if [[ "$ARGS_I_INT_CONTENT" != *"--setting-sources"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (i) --setting-sources absent in interactive\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (i) --setting-sources present in interactive\n  got: %s\n' "${ARGS_I_INT_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
    if [[ "$ARGS_I_INT_CONTENT" != *"--print"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (i) --print absent in interactive\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (i) --print present in interactive\n  got: %s\n' "${ARGS_I_INT_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
    if [[ "$ARGS_I_INT_CONTENT" != *"--no-session-persistence"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (i) --no-session-persistence absent in interactive\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (i) --no-session-persistence present in interactive\n  got: %s\n' "${ARGS_I_INT_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
    if [[ "$ARGS_I_INT_CONTENT" != *"--disable-slash-commands"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (i) --disable-slash-commands absent in interactive\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (i) --disable-slash-commands present in interactive\n  got: %s\n' "${ARGS_I_INT_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
else
    if [[ ! -f "$ARGS_I_NI" ]]; then
        printf 'FAIL: (i) non-interactive args file not created\n'
    fi
    if [[ ! -f "$ARGS_I_INT" ]]; then
        printf 'FAIL: (i) interactive args file not created\n'
    fi
    fail=$((fail + 10))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (j): --resumable opt-in gates --no-session-persistence / --no-session;
#           --resume-id adds --resume (claude) / --session (pi); guard + parity
# ─────────────────────────────────────────────────────────────────────────────
CB_J="$(make_cb_root cb_j)"
make_claude_harness "$CB_J" >/dev/null
CLAUDE_J_DIR="$BASE_TMP/bin_j"
mkdir -p "$CLAUDE_J_DIR"
make_stub "$CLAUDE_J_DIR/claude" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'

run_claude_j() { # $1=args-file  $2..=extra codegen-build flags before prompt
    local out="$1"
    shift
    TARGET_ARGS_FILE="$out" \
        PATH="$CLAUDE_J_DIR:$PATH" \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        "$CB_J/codegen-build" --harness=claude --stack=phoenix "$@" \
        "j prompt" 2>/dev/null || true
}

# (j1) default headless STILL has --no-session-persistence
J1="$BASE_TMP/args_j1.txt"
run_claude_j "$J1" --non-interactive
assert_contains "(j1) default headless keeps --no-session-persistence" "$(cat "$J1")" "--no-session-persistence"

# (j2) --resumable headless OMITS --no-session-persistence
J2="$BASE_TMP/args_j2.txt"
run_claude_j "$J2" --non-interactive --resumable
J2C="$(cat "$J2")"
if [[ "$J2C" != *"--no-session-persistence"* ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (j2) --resumable drops --no-session-persistence\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (j2) --resumable still has --no-session-persistence\n  got: %s\n' "${J2C:0:300}"
    fail=$((fail + 1))
fi

# (j3) --resumable --resume-id=SID123 adds --resume SID123
J3="$BASE_TMP/args_j3.txt"
run_claude_j "$J3" --non-interactive --resumable --resume-id=SID123
J3C="$(cat "$J3")"
assert_contains "(j3) --resume flag present" "$J3C" "--resume"
assert_contains "(j3) resume id forwarded" "$J3C" "SID123"

# (j4) --resumable WITHOUT id → no --resume, no --no-session-persistence
J4="$BASE_TMP/args_j4.txt"
run_claude_j "$J4" --non-interactive --resumable
J4C="$(cat "$J4")"
if [[ "$J4C" != *"--resume"* ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (j4) no --resume when id absent\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (j4) --resume present without id\n  got: %s\n' "${J4C:0:300}"
    fail=$((fail + 1))
fi

# (j5) interactive + --resumable → no --resume, no --no-session-persistence
J5="$BASE_TMP/args_j5.txt"
CODEGEN_BUILD_NON_INTERACTIVE="" TARGET_ARGS_FILE="$J5" \
    PATH="$CLAUDE_J_DIR:$PATH" OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_J/codegen-build" --harness=claude --stack=phoenix --resumable "j prompt" 2>/dev/null || true
J5C="$(cat "$J5")"
if [[ "$J5C" != *"--resume"* && "$J5C" != *"--no-session-persistence"* ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (j5) interactive omits resume + persistence flags\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (j5) interactive leaked a non-interactive flag\n  got: %s\n' "${J5C:0:300}"
    fail=$((fail + 1))
fi

# (j6) --resume-id WITHOUT --resumable → exit 2 (usage guard)
actual_ec=0
"$CB_J/codegen-build" --harness=claude --stack=phoenix --non-interactive --resume-id=SID "j prompt" 2>/dev/null || actual_ec=$?
check "(j6) --resume-id without --resumable exits 2" "2" "$actual_ec"

# ── Pi parity ──
CB_JP="$(make_cb_root cb_jp)"
make_pi_harness "$CB_JP" >/dev/null
PI_J_DIR="$BASE_TMP/bin_jp"
mkdir -p "$PI_J_DIR"
make_stub "$PI_J_DIR/pi" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'

run_pi_j() {
    local out="$1"
    shift
    TARGET_ARGS_FILE="$out" PATH="$PI_J_DIR:$PATH" OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        "$CB_JP/codegen-build" --harness=pi --stack=phoenix "$@" "jp prompt" 2>/dev/null || true
}

# (j7) Pi default headless STILL has --no-session
J7="$BASE_TMP/args_j7.txt"
run_pi_j "$J7" --non-interactive
assert_contains "(j7) pi default headless keeps --no-session" "$(cat "$J7")" "--no-session"

# (j8) Pi --resumable OMITS --no-session
J8="$BASE_TMP/args_j8.txt"
run_pi_j "$J8" --non-interactive --resumable
J8C="$(cat "$J8")"
if [[ "$J8C" != *"--no-session"* ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (j8) pi --resumable drops --no-session\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (j8) pi --resumable still has --no-session\n  got: %s\n' "${J8C:0:300}"
    fail=$((fail + 1))
fi

# (j9) Pi --resumable --resume-id=PID9 adds --session PID9
J9="$BASE_TMP/args_j9.txt"
run_pi_j "$J9" --non-interactive --resumable --resume-id=PID9
J9C="$(cat "$J9")"
assert_contains "(j9) pi --session flag present" "$J9C" "--session"
assert_contains "(j9) pi resume id forwarded" "$J9C" "PID9"

# ─────────────────────────────────────────────────────────────────────────────
# Test (k): install-launcher self-build — $SCRIPT_DIR (cb_root) ≠ $CWD, but $CWD
# carries the codegen repo markers ⇒ integrate pre-step MUST be skipped.
# This is the case the location-based guard ($CWD == $SCRIPT_DIR) missed.
# ─────────────────────────────────────────────────────────────────────────────
CB_K="$(make_cb_root cb_k)"
make_claude_harness "$CB_K" >/dev/null
# Copy real codegen-scaffold so SCAFFOLD_CMD is executable and the integrate
# pre-step block actually runs (otherwise the guard is never reached).
cp "$CODEGEN_ROOT/codegen-scaffold" "$CB_K/codegen-scaffold"
chmod +x "$CB_K/codegen-scaffold"

# Marker-bearing $CWD distinct from cb_root (= $SCRIPT_DIR). Simulates running
# the INSTALLED launcher against the codegen repo root.
MARKER_CWD="$BASE_TMP/marker_cwd"
mkdir -p "$MARKER_CWD/harnesses/claude" "$MARKER_CWD/templates/generator"
touch "$MARKER_CWD/harnesses/claude/manifest.yaml" "$MARKER_CWD/templates/generator/generate.sh"

# Dispatch stub exits 0 so the build short-circuits right after the integrate pre-step.
make_stub "$CB_K/harnesses/claude/dispatch.sh" 'exit 0'

STDERR_K="$BASE_TMP/stderr_k.txt"
actual_ec=0
OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_K/codegen-build" --harness=claude --stack=phoenix --non-interactive \
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
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
