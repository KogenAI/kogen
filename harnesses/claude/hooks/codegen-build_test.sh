#!/usr/bin/env bash
# codegen-build_test.sh — unit tests for codegen-build, dispatch.sh (claude + pi).
#
# Engine selection: --elixir is a boolean engine selector — present ⇒ the
# deterministic Elixir orchestration loop (mix codegen.loop); absent ⇒ the
# legacy self-orchestrating harness session (the default). --non-interactive
# is now legacy-engine-I/O-mode-only (headless stream-json vs interactive UI)
# and is fully decoupled from engine choice.
#
# Tests:
#  (a) --harness=claude --elixir non-interactive → dispatch.sh execs `mix
#      codegen.loop --harness=claude_code ...` (loop path)
#  (b) --harness=pi --elixir non-interactive → dispatch.sh execs `mix
#      codegen.loop --harness=pi ...`
#  (c) missing --harness exits 2 with usage on stderr
#  (d) missing prompt exits 2
#  (e) exit codes 0/1/2/130 propagate from stub
#  (f) stdout passes through fixture stream-json byte-identical (interactive
#      mode only — the loop path's stdout is `mix`'s own output, not a
#      byte-transparent claude stream-json passthrough; see test (f) below)
#  (m) --elixir + --resume-id/--resumable → usage error exit 2 (loop is not
#      resumable)
#  (n) --elixir --non-interactive <prompt> → mix codegen.loop invoked
#  (o) --non-interactive WITHOUT --elixir → legacy claude stub invoked, mix
#      NOT invoked (new default: legacy engine)
#  (p1) --stack omitted, cwd has mix.exs only → detects phoenix
#  (p2) --stack omitted, cwd has vite.config.js only → detects static
#  (p3) --stack omitted, cwd has BOTH mix.exs and vite.config.js → ambiguous,
#       exit 2
#  (p4) --stack omitted, cwd has neither marker → cannot detect, exit 2
#  (p5) --stack omitted, cwd has self-build markers → detects phoenix
#       (self-build precedence over mix.exs/vite.config.js sniffs)

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
# Test (a): --harness=claude --elixir non-interactive → dispatch.sh execs
# `mix codegen.loop --harness=claude_code ...` (loop path)
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
    "$CB_A/codegen-build" --harness=claude --stack=phoenix --elixir --non-interactive \
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
# Test (b): --harness=pi --elixir non-interactive → dispatch.sh execs
# `mix codegen.loop --harness=pi ...` (loop path)
# ─────────────────────────────────────────────────────────────────────────────
CB_B="$(make_cb_root cb_b)"
make_pi_harness "$CB_B" >/dev/null

ARGS_B="$BASE_TMP/args_b.txt"
MIX_B_DIR="$BASE_TMP/bin_b"
make_mix_stub "$MIX_B_DIR"
# Create a pi stub so dispatch.sh's command -v pi doesn't exit 127
make_stub "$MIX_B_DIR/pi" "exit 0"

actual_ec=0
TARGET_ARGS_FILE="$ARGS_B" \
    PATH="$MIX_B_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_B/codegen-build" --harness=pi --stack=phoenix --elixir --non-interactive \
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
# --elixir non-interactive/no-resume execs the loop; the fixture stubs
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
    "$CB_F/codegen-build" --harness=claude --stack=phoenix --elixir --non-interactive \
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
# Test (i): --elixir non-interactive → mix codegen.loop invoked (loop path,
#           argv carries --harness=claude_code/--stack/--cwd, not the
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
    "$CB_I/codegen-build" --harness=claude --stack=phoenix --elixir --non-interactive \
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
#           j1/j2/j4/j7/j8 pass --elixir (loop path): loop condition
#           (-n "$ELIXIR_ENGINE" && -z "$RESUME_ID") holds → dispatch execs
#           `mix codegen.loop` regardless of --resumable (the loop's own
#           per-role codegen-call handles persistence, not dispatch.sh's
#           direct exec argv). j3/j9 do NOT pass --elixir and carry a
#           resume-id → dispatch falls through to the direct claude/pi exec
#           so --resume/--session still forward correctly. j5 (interactive)
#           and j6 (usage guard) are unaffected.
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

# (j1) --elixir, no resume-id, non-interactive → loop path (mix codegen.loop invoked)
J1="$BASE_TMP/args_j1.txt"
run_mix_j "$J1" --elixir --non-interactive
assert_contains "(j1) no resume-id: mix codegen.loop invoked" "$(cat "$J1")" "codegen.loop"

# (j2) --elixir, non-interactive, no --resumable/--resume-id → loop path
# (kept as a second confirming case alongside j1; --elixir + --resumable is
# rejected outright — see test (m)).
J2="$BASE_TMP/args_j2.txt"
run_mix_j "$J2" --elixir --non-interactive
assert_contains "(j2) --elixir non-interactive: mix codegen.loop invoked" "$(cat "$J2")" "codegen.loop"

# (j3) --resumable --resume-id=SID123 → RESUME_ID set → loop condition false
# → falls through to the OLD direct claude exec path (unaffected by cutover)
J3="$BASE_TMP/args_j3.txt"
run_claude_j "$J3" --non-interactive --resumable --resume-id=SID123
J3C="$(cat "$J3")"
assert_contains "(j3) --resume flag present" "$J3C" "--resume"
assert_contains "(j3) resume id forwarded" "$J3C" "SID123"

# (j4) --elixir, no resume-id, non-interactive → loop path (dup of j1/j2,
# kept for numbering continuity)
J4="$BASE_TMP/args_j4.txt"
run_mix_j "$J4" --elixir --non-interactive
assert_contains "(j4) --elixir non-interactive: mix codegen.loop invoked" "$(cat "$J4")" "codegen.loop"

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

# (j7) Pi --elixir, no resume-id, non-interactive → loop path (mix codegen.loop invoked)
J7="$BASE_TMP/args_j7.txt"
run_mix_pi_j "$J7" --elixir --non-interactive
assert_contains "(j7) pi no resume-id: mix codegen.loop invoked" "$(cat "$J7")" "codegen.loop"

# (j8) Pi --resumable WITHOUT --elixir, no resume-id, non-interactive →
# legacy exec path (pi stub); --resumable set → --no-session dropped
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
# Test (m): --elixir + --resumable/--resume-id → usage error exit 2 (the
# Elixir loop is not resumable).
# ─────────────────────────────────────────────────────────────────────────────
CB_M="$(make_cb_root cb_m)"
make_claude_harness "$CB_M" >/dev/null

actual_ec=0
stderr_m1=$("$CB_M/codegen-build" --harness=claude --stack=phoenix --elixir \
    --resumable --resume-id=X "m prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(m) --elixir + --resumable + --resume-id exits 2" "2" "$actual_ec"
assert_contains "(m) stderr mentions not resumable" "$stderr_m1" "not resumable"

actual_ec=0
stderr_m2=$("$CB_M/codegen-build" --harness=claude --stack=phoenix --elixir \
    --resumable "m prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(m) --elixir + --resumable (no id) exits 2" "2" "$actual_ec"
assert_contains "(m) stderr mentions not resumable (resumable-only)" "$stderr_m2" "not resumable"

# ─────────────────────────────────────────────────────────────────────────────
# Test (n): --elixir --non-interactive <prompt> → mix codegen.loop invoked.
# ─────────────────────────────────────────────────────────────────────────────
CB_N="$(make_cb_root cb_n)"
make_claude_harness "$CB_N" >/dev/null

ARGS_N="$BASE_TMP/args_n.txt"
MIX_N_DIR="$BASE_TMP/bin_n"
make_mix_stub "$MIX_N_DIR"

actual_ec=0
TARGET_ARGS_FILE="$ARGS_N" \
    PATH="$MIX_N_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_N/codegen-build" --harness=claude --stack=phoenix --elixir --non-interactive \
    "n prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_N" ]]; then
    assert_contains "(n) --elixir non-interactive invokes mix codegen.loop" "$(cat "$ARGS_N")" "codegen.loop"
else
    printf 'FAIL: (n) args file not created — mix stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (o): --non-interactive WITHOUT --elixir → legacy claude stub invoked
# (new default engine), mix NOT invoked.
# ─────────────────────────────────────────────────────────────────────────────
CB_O="$(make_cb_root cb_o)"
make_claude_harness "$CB_O" >/dev/null

ARGS_O="$BASE_TMP/args_o.txt"
MIX_O_DIR="$BASE_TMP/bin_o_mix"
make_mix_stub "$MIX_O_DIR"
CLAUDE_O_DIR="$BASE_TMP/bin_o_claude"
mkdir -p "$CLAUDE_O_DIR"
make_stub "$CLAUDE_O_DIR/claude" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'

actual_ec=0
TARGET_ARGS_FILE="$ARGS_O" \
    PATH="$CLAUDE_O_DIR:$MIX_O_DIR:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
    "$CB_O/codegen-build" --harness=claude --stack=phoenix --non-interactive \
    "o prompt" 2>/dev/null ||
    actual_ec=$?

if [[ -f "$ARGS_O" ]]; then
    ARGS_O_CONTENT="$(cat "$ARGS_O")"
    assert_contains "(o) legacy claude stub invoked (no --elixir)" "$ARGS_O_CONTENT" "--print"
    if [[ "$ARGS_O_CONTENT" != *"codegen.loop"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (o) mix codegen.loop NOT invoked\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: (o) mix codegen.loop invoked despite --elixir absent\n  got: %s\n' "${ARGS_O_CONTENT:0:300}"
        fail=$((fail + 1))
    fi
else
    printf 'FAIL: (o) args file not created — claude stub not invoked (exit: %s)\n' "$actual_ec"
    fail=$((fail + 2))
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
make_stub "$CB_P1/harnesses/claude/dispatch.sh" 'exit 0'
MARKER_P1="$BASE_TMP/marker_p1"
mkdir -p "$MARKER_P1"
touch "$MARKER_P1/mix.exs"

actual_ec=0
stderr_p1=$("$CB_P1/codegen-build" --harness=claude --cwd="$MARKER_P1" --non-interactive \
    "p1 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p1) mix.exs-only detects phoenix: exit 0" "0" "$actual_ec"
assert_contains "(p1) stderr reports detected stack=phoenix" "$stderr_p1" "detected stack=phoenix from cwd markers"

# (p2) vite.config.js only → detects static
CB_P2="$(make_cb_root cb_p2)"
mkdir -p "$CB_P2/harnesses/claude"
make_stub "$CB_P2/harnesses/claude/dispatch.sh" 'exit 0'
MARKER_P2="$BASE_TMP/marker_p2"
mkdir -p "$MARKER_P2"
touch "$MARKER_P2/vite.config.js"

actual_ec=0
stderr_p2=$("$CB_P2/codegen-build" --harness=claude --cwd="$MARKER_P2" --non-interactive \
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
stderr_p3=$("$CB_P3/codegen-build" --harness=claude --cwd="$MARKER_P3" --non-interactive \
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
stderr_p4=$("$CB_P4/codegen-build" --harness=claude --cwd="$MARKER_P4" --non-interactive \
    "p4 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(p4) no markers: cannot detect exit 2" "2" "$actual_ec"
assert_contains "(p4) stderr mentions cannot detect stack" "$stderr_p4" "cannot detect stack"

# (p5) self-build markers present → detects phoenix (case-2 precedence)
CB_P5="$(make_cb_root cb_p5)"
mkdir -p "$CB_P5/harnesses/claude"
make_stub "$CB_P5/harnesses/claude/dispatch.sh" 'exit 0'
MARKER_P5="$BASE_TMP/marker_p5"
mkdir -p "$MARKER_P5/harnesses/claude" "$MARKER_P5/templates/generator"
touch "$MARKER_P5/harnesses/claude/manifest.yaml" "$MARKER_P5/templates/generator/generate.sh"

actual_ec=0
stderr_p5=$("$CB_P5/codegen-build" --harness=claude --cwd="$MARKER_P5" --non-interactive \
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
make_stub "$CB_Q1/harnesses/claude/dispatch.sh" 'exit 0'
printf '1\n' >"$CB_Q1/shared/scaffold/SCHEMA_VERSION"
MARKER_Q1="$BASE_TMP/marker_q1"
mkdir -p "$MARKER_Q1"

actual_ec=0
stderr_q1=$("$CB_Q1/codegen-build" --harness=claude --stack=static --cwd="$MARKER_Q1" --non-interactive \
    "q1 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q1) manifest absent: proceeds exit 0" "0" "$actual_ec"
q1_refused=$(printf '%s' "$stderr_q1" | grep -c "app wired at scaffold schema" || true)
check "(q1) no refuse message when manifest absent" "0" "$q1_refused"

# (q2) stamped version equals current → proceeds
CB_Q2="$(make_cb_root cb_q2)"
mkdir -p "$CB_Q2/harnesses/claude" "$CB_Q2/shared/scaffold"
make_stub "$CB_Q2/harnesses/claude/dispatch.sh" 'exit 0'
printf '1\n' >"$CB_Q2/shared/scaffold/SCHEMA_VERSION"
MARKER_Q2="$BASE_TMP/marker_q2"
mkdir -p "$MARKER_Q2/codegen"
printf 'scaffold_schema_version: 1\nscaffolded_from_sha: abc123\nscaffolded_at: 2026-01-01T00:00:00Z\n' \
    >"$MARKER_Q2/codegen/manifest.yaml"

actual_ec=0
stderr_q2=$("$CB_Q2/codegen-build" --harness=claude --stack=static --cwd="$MARKER_Q2" --non-interactive \
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
stderr_q3=$("$CB_Q3/codegen-build" --harness=claude --stack=static --cwd="$MARKER_Q3" --non-interactive \
    "q3 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q3) stamped version behind current: refuse exit 2" "2" "$actual_ec"
assert_contains "(q3) stderr names remediation command" "$stderr_q3" "codegen-scaffold integrate"
assert_contains "(q3) stderr reports stamped v0" "$stderr_q3" "v0"
assert_contains "(q3) stderr reports current v1" "$stderr_q3" "v1"

# (q4) self-build markers present + behind manifest → preflight skipped, proceeds
CB_Q4="$(make_cb_root cb_q4)"
mkdir -p "$CB_Q4/harnesses/claude" "$CB_Q4/shared/scaffold"
make_stub "$CB_Q4/harnesses/claude/dispatch.sh" 'exit 0'
printf '1\n' >"$CB_Q4/shared/scaffold/SCHEMA_VERSION"
MARKER_Q4="$BASE_TMP/marker_q4"
mkdir -p "$MARKER_Q4/codegen" "$MARKER_Q4/harnesses/claude" "$MARKER_Q4/templates/generator"
touch "$MARKER_Q4/harnesses/claude/manifest.yaml" "$MARKER_Q4/templates/generator/generate.sh"
printf 'scaffold_schema_version: 0\nscaffolded_from_sha: abc123\nscaffolded_at: 2026-01-01T00:00:00Z\n' \
    >"$MARKER_Q4/codegen/manifest.yaml"

actual_ec=0
stderr_q4=$("$CB_Q4/codegen-build" --harness=claude --stack=phoenix --cwd="$MARKER_Q4" --non-interactive \
    "q4 prompt" 2>&1 >/dev/null) || actual_ec=$?
check "(q4) self-build markers present: preflight skipped, proceeds exit 0" "0" "$actual_ec"
q4_refused=$(printf '%s' "$stderr_q4" | grep -c "app wired at scaffold schema" || true)
check "(q4) no refuse message on self-build even with behind manifest" "0" "$q4_refused"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
