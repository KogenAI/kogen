#!/usr/bin/env bash
# codegen-build_test.sh — unit tests for codegen-build, dispatch.sh (claude + pi).
#
# Tests:
#  (a) --harness=claude non-interactive → dispatch.sh execs `mix codegen.loop
#      --harness=claude_code ...` (the unconditional build-mode loop path)
#  (b) --harness=pi non-interactive → dispatch.sh execs `mix codegen.loop
#      --harness=pi ...`
#  (c) missing --harness exits 2 with usage on stderr
#  (d) missing prompt exits 2
#  (e) exit codes 0/1/2/130 propagate from stub
#  (f) stdout passes through fixture stream-json byte-identical (interactive
#      mode only — the loop path's stdout is `mix`'s own output, not a
#      byte-transparent claude stream-json passthrough; see test (f) below)

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
    cp "$REAL_PI_HARNESS/manifest.yaml" "$harness_dir/manifest.yaml"
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

# make_mix_stub <dir> <target-args-file-env-var-default>
# Build-mode non-interactive/no-resume dispatch always execs
# `mix codegen.loop ...` (unconditional loop path, no CODEGEN_BUILD_USE_LOOP
# flag). Stub `mix` so these hermetic tests never invoke a real LLM/ExUnit
# round-trip; captures argv to the file named by $TARGET_ARGS_FILE (or
# /dev/null if unset).
make_mix_stub() {
    local dir="$1"
    mkdir -p "$dir"
    make_stub "$dir/mix" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'
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
# Test (a): --harness=claude non-interactive → dispatch.sh execs
# `mix codegen.loop --harness=claude_code ...` (unconditional loop path)
# ─────────────────────────────────────────────────────────────────────────────
CB_A="$(make_cb_root cb_a)"
make_claude_harness "$CB_A" >/dev/null

ARGS_A="$BASE_TMP/args_a.txt"
MIX_A_DIR="$BASE_TMP/bin_a"
make_mix_stub "$MIX_A_DIR"

actual_ec=0
TARGET_ARGS_FILE="$ARGS_A" \
    PATH="$MIX_A_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_A/codegen-build" --harness=claude --stack=phoenix --non-interactive \
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
# Test (b): --harness=pi non-interactive → dispatch.sh execs
# `mix codegen.loop --harness=pi ...` (unconditional loop path)
# ─────────────────────────────────────────────────────────────────────────────
CB_B="$(make_cb_root cb_b)"
make_pi_harness "$CB_B" >/dev/null

ARGS_B="$BASE_TMP/args_b.txt"
MIX_B_DIR="$BASE_TMP/bin_b"
make_mix_stub "$MIX_B_DIR"

actual_ec=0
TARGET_ARGS_FILE="$ARGS_B" \
    PATH="$MIX_B_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_B/codegen-build" --harness=pi --stack=phoenix --non-interactive \
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

# ─────────────────────────────────────────────────────────────────────────────
# Test (b2): --harness=pi exits non-zero when dispatch succeeds but gate verdict is missing
# ─────────────────────────────────────────────────────────────────────────────
CB_B2="$(make_cb_root cb_b2)"
mkdir -p "$CB_B2/harnesses/pi"
make_stub "$CB_B2/harnesses/pi/dispatch.sh" 'exit 0'

actual_ec=0
(
    cd "$CB_B2"
    ./codegen-build --harness=pi --stack=phoenix --non-interactive "pi prompt" 2>"$BASE_TMP/stderr_b2"
) || actual_ec=$?

stderr_b2="$(cat "$BASE_TMP/stderr_b2")"
check "(b2) missing gate result exits non-zero" "1" "$actual_ec"
assert_contains "(b2) stderr mentions missing gate-result.json" "$stderr_b2" "gate-result.json"
assert_contains "(b2) stderr is fail-closed" "$stderr_b2" "missing"

# ─────────────────────────────────────────────────────────────────────────────
# Test (b3): --harness=pi succeeds when dispatch writes a clear gate result
# ─────────────────────────────────────────────────────────────────────────────
CB_B3="$(make_cb_root cb_b3)"
mkdir -p "$CB_B3/harnesses/pi"
make_stub "$CB_B3/harnesses/pi/dispatch.sh" '
mkdir -p codegen/gate-pending
cat > codegen/gate-pending/gate-result.json <<"JSON"
{"verdict":"clear"}
JSON
exit 0
'

actual_ec=0
(
    cd "$CB_B3"
    ./codegen-build --harness=pi --stack=phoenix --non-interactive "pi prompt" >/dev/null 2>&1
) || actual_ec=$?
check "(b3) clear gate result exits 0" "0" "$actual_ec"

# ─────────────────────────────────────────────────────────────────────────────
# Test (f): stdout byte-identical pass-through — codegen-build → dispatch.sh
# → exec mix codegen.loop must not buffer/transform the child's stdout.
# Non-interactive/no-resume always execs the loop now; the fixture stubs
# `mix` itself (rather than `claude`) since that's the real exec target.
# ─────────────────────────────────────────────────────────────────────────────
FIXTURE_LINE='{"type":"result","is_error":false,"usage":{"input_tokens":42,"output_tokens":7}}'

CB_F="$(make_cb_root cb_f)"
make_claude_harness "$CB_F" >/dev/null

MIX_F_DIR="$BASE_TMP/bin_f"
mkdir -p "$MIX_F_DIR"
make_stub "$MIX_F_DIR/mix" "printf '%s\n' '${FIXTURE_LINE}'"

ACTUAL_F_OUT=$(PATH="$MIX_F_DIR:$PATH" \
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
# Test (i): non-interactive → mix codegen.loop invoked (unconditional loop
#           path, argv carries --harness=claude_code/--stack/--cwd, not the
#           claude print-family flags — those now live inside the loop's own
#           per-role codegen-call, not dispatch.sh's direct exec argv).
#           Interactive mode is unaffected — --system-prompt and
#           --dangerously-skip-permissions present, print-family flags absent.
# ─────────────────────────────────────────────────────────────────────────────
CB_I="$(make_cb_root cb_i)"
make_claude_harness "$CB_I" >/dev/null

ARGS_I_NI="$BASE_TMP/args_i_ni.txt"
ARGS_I_INT="$BASE_TMP/args_i_int.txt"
MIX_I_DIR="$BASE_TMP/bin_i"
make_mix_stub "$MIX_I_DIR"
CLAUDE_I_DIR="$BASE_TMP/bin_i_claude"
mkdir -p "$CLAUDE_I_DIR"
make_stub "$CLAUDE_I_DIR/claude" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'

# Non-interactive run (loop path — mix stub)
actual_ec=0
TARGET_ARGS_FILE="$ARGS_I_NI" \
    PATH="$MIX_I_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_I/codegen-build" --harness=claude --stack=phoenix --non-interactive \
    "test prompt i" 2>/dev/null ||
    actual_ec=$?

# Interactive run (unaffected — claude stub, direct exec)
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

    # Non-interactive: mix codegen.loop invoked with the loop's own argv
    assert_contains "(i) mix codegen.loop invoked in non-interactive" "$ARGS_I_NI_CONTENT" "codegen.loop"
    assert_contains "(i) --harness=claude_code in non-interactive loop argv" "$ARGS_I_NI_CONTENT" "--harness=claude_code"
    assert_contains "(i) prompt forwarded in non-interactive loop argv" "$ARGS_I_NI_CONTENT" "test prompt i"

    # Interactive: --system-prompt and --dangerously-skip-permissions present
    assert_contains "(i) --system-prompt in interactive" "$ARGS_I_INT_CONTENT" "--system-prompt"
    assert_contains "(i) --dangerously-skip-permissions in interactive" "$ARGS_I_INT_CONTENT" "--dangerously-skip-permissions"

    # Interactive: print-family flags absent (unaffected by the loop cutover)
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
    fail=$((fail + 7))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (j): --resumable/--resume-id gate which exec target dispatch.sh uses.
#           No resume-id (j1/j2/j4/j7/j8): loop condition (-z "$RESUME_ID")
#           holds → dispatch execs `mix codegen.loop` regardless of
#           --resumable (the loop's own per-role codegen-call handles
#           persistence, not dispatch.sh's direct exec argv). With a
#           resume-id (j3/j9): RESUME_ID is non-empty → loop condition is
#           false → dispatch falls through to the OLD direct claude/pi exec
#           (unaffected by the cutover) so --resume/--session still forward
#           correctly. j5 (interactive) and j6 (usage guard) are unaffected.
# ─────────────────────────────────────────────────────────────────────────────
CB_J="$(make_cb_root cb_j)"
make_claude_harness "$CB_J" >/dev/null
CLAUDE_J_DIR="$BASE_TMP/bin_j"
mkdir -p "$CLAUDE_J_DIR"
make_stub "$CLAUDE_J_DIR/claude" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'
MIX_J_DIR="$BASE_TMP/bin_j_mix"
make_mix_stub "$MIX_J_DIR"

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

# run_mix_j: same as run_claude_j but PATHs the mix stub first (loop path cases)
run_mix_j() {
    local out="$1"
    shift
    TARGET_ARGS_FILE="$out" \
        PATH="$MIX_J_DIR:$CLAUDE_J_DIR:$PATH" \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        "$CB_J/codegen-build" --harness=claude --stack=phoenix "$@" \
        "j prompt" 2>/dev/null || true
}

# (j1) no resume-id, non-interactive → loop path (mix codegen.loop invoked)
J1="$BASE_TMP/args_j1.txt"
run_mix_j "$J1" --non-interactive
assert_contains "(j1) no resume-id: mix codegen.loop invoked" "$(cat "$J1")" "codegen.loop"

# (j2) --resumable, no resume-id, non-interactive → STILL loop path
# (--resumable alone does not set RESUME_ID; the loop condition only checks
# RESUME_ID emptiness, so this is identical dispatch behavior to j1)
J2="$BASE_TMP/args_j2.txt"
run_mix_j "$J2" --non-interactive --resumable
assert_contains "(j2) --resumable without resume-id: mix codegen.loop invoked" "$(cat "$J2")" "codegen.loop"

# (j3) --resumable --resume-id=SID123 → RESUME_ID set → loop condition false
# → falls through to the OLD direct claude exec path (unaffected by cutover)
J3="$BASE_TMP/args_j3.txt"
run_claude_j "$J3" --non-interactive --resumable --resume-id=SID123
J3C="$(cat "$J3")"
assert_contains "(j3) --resume flag present" "$J3C" "--resume"
assert_contains "(j3) resume id forwarded" "$J3C" "SID123"

# (j4) --resumable WITHOUT id, non-interactive → loop path (same as j1/j2)
J4="$BASE_TMP/args_j4.txt"
run_mix_j "$J4" --non-interactive --resumable
assert_contains "(j4) --resumable without id: mix codegen.loop invoked" "$(cat "$J4")" "codegen.loop"

# (j5) interactive + --resumable → NON_INTERACTIVE unset → loop condition
# false regardless of RESUME_ID → falls through to old direct claude exec
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
MIX_JP_DIR="$BASE_TMP/bin_jp_mix"
make_mix_stub "$MIX_JP_DIR"

run_pi_j() {
    local out="$1"
    shift
    TARGET_ARGS_FILE="$out" PATH="$PI_J_DIR:$PATH" OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        "$CB_JP/codegen-build" --harness=pi --stack=phoenix "$@" "jp prompt" 2>/dev/null || true
}

# run_mix_pi_j: same as run_pi_j but PATHs the mix stub first (loop path cases)
run_mix_pi_j() {
    local out="$1"
    shift
    TARGET_ARGS_FILE="$out" PATH="$MIX_JP_DIR:$PI_J_DIR:$PATH" OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        "$CB_JP/codegen-build" --harness=pi --stack=phoenix "$@" "jp prompt" 2>/dev/null || true
}

# (j7) Pi, no resume-id, non-interactive → loop path (mix codegen.loop invoked)
J7="$BASE_TMP/args_j7.txt"
run_mix_pi_j "$J7" --non-interactive
assert_contains "(j7) pi no resume-id: mix codegen.loop invoked" "$(cat "$J7")" "codegen.loop"

# (j8) Pi --resumable, no resume-id, non-interactive → STILL loop path
J8="$BASE_TMP/args_j8.txt"
run_mix_pi_j "$J8" --non-interactive --resumable
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
