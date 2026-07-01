#!/usr/bin/env bash
# dispatch_test.sh — hermetic unit tests for harnesses/pi/dispatch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle" 2>/dev/null; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:400}"
        fail=$((fail + 1))
    fi
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle" 2>/dev/null; then
        printf 'FAIL: %s — unexpected match for %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:400}"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"
exit 0
STUB
chmod +x "$FAKE_BIN/pi"

# Fake mix stub: build mode is unconditional now (no CODEGEN_BUILD_USE_LOOP
# flag) — the non-interactive/no-resume path always execs
# `mix codegen.loop`. Stub it so these hermetic tests never invoke a real
# LLM/ExUnit round-trip; capture argv + env for assertions.
cat >"$FAKE_BIN/mix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${TARGET_MIX_ARGS_FILE:-/dev/null}"
env >> "${TARGET_MIX_ARGS_FILE:-/dev/null}"
exit 0
STUB
chmod +x "$FAKE_BIN/mix"

make_temp_dispatch() {
    local root="$1"
    mkdir -p "$root"
    cp "$DISPATCH" "$root/dispatch.sh"
    cp "$CODEGEN_ROOT/harnesses/pi/manifest.yaml" "$root/manifest.yaml"
    chmod +x "$root/dispatch.sh"
}

# ── Test 1: build mode is unconditional → execs mix codegen.loop (not pi) ─────
# Historically this test asserted the pi stub ran directly with
# --extension/--system-prompt flags forwarded. Under the unconditional loop
# cutover, the non-interactive/no-resume build path always execs
# `mix codegen.loop --harness=pi ...` instead — the pi stub only runs when
# the loop's `RoleResolver`/`codegen-call` round-trip later invokes pi
# per-role (out of scope for this hermetic dispatch-level test).
TEST1_HARNESS="$TMP_ROOT/harnesses/pi"
make_temp_dispatch "$TEST1_HARNESS"
printf 'generated build prompt sentinel\n' >"$TEST1_HARNESS/pi-build-system-prompt.txt"
mkdir -p "$TMP_ROOT/project"

MIX_ARGS_FILE_1="$TMP_ROOT/mix-args-1.txt"
rc=0
TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_1" \
    PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="test-model" \
    CODEGEN_BUILD_EFFORT="low" \
    CODEGEN_BUILD_NON_INTERACTIVE=1 \
    CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
    "$TEST1_HARNESS/dispatch.sh" --extension "$TMP_ROOT/custom-extension" "hello prompt" \
    >/dev/null 2>&1 || rc=$?

assert_eq "loop path: exit 0 (mix stub)" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE_1" ]]; then
    MIX_ARGS_CONTENT="$(cat "$MIX_ARGS_FILE_1")"
    assert_contains "loop path: mix codegen.loop invoked" "$MIX_ARGS_CONTENT" "codegen.loop"
    assert_contains "loop path: --harness=pi passed" "$MIX_ARGS_CONTENT" "--harness=pi"
    assert_contains "loop path: --stack passed" "$MIX_ARGS_CONTENT" "--stack="
    assert_contains "loop path: --cwd passed" "$MIX_ARGS_CONTENT" "$TMP_ROOT/project"
    assert_contains "loop path: prompt forwarded" "$MIX_ARGS_CONTENT" "hello prompt"
else
    printf 'FAIL: loop path — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 1b: missing test_harness/ dir → exit 2 (fail loud, no silent fallback) ──
TEST1B_HARNESS="$TMP_ROOT/no-loop-dir/harnesses/pi"
make_temp_dispatch "$TEST1B_HARNESS"
printf 'generated build prompt sentinel\n' >"$TEST1B_HARNESS/pi-build-system-prompt.txt"
FAKE_CODEGEN_NO_LOOP="$TMP_ROOT/fake-codegen-no-loop"
mkdir -p "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/pi-extensions/askuserquestion"
mkdir -p "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/pi-extensions/subagents"
mkdir -p "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/pi-extensions/enforcement"
cp "$TEST1B_HARNESS/dispatch.sh" "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/dispatch.sh"
cp "$TEST1B_HARNESS/manifest.yaml" "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/manifest.yaml"
cp "$TEST1B_HARNESS/pi-build-system-prompt.txt" "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/pi-build-system-prompt.txt"
mkdir -p "$TMP_ROOT/no-loop-dir/project"

rc=0
out=$(
    PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_NO_LOOP" \
        CODEGEN_BUILD_MODEL="test-model" \
        CODEGEN_BUILD_EFFORT="low" \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        CODEGEN_BUILD_CWD="$TMP_ROOT/no-loop-dir/project" \
        "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "missing test_harness/ dir: exit code 2" "2" "$rc"
assert_contains "missing test_harness/ dir: stderr mentions 'orchestration loop dir not found'" \
    "$out" "orchestration loop dir not found"

# ── Test 2: missing generated prompt fails loud before model launch ───────────
TEST2_HARNESS="$TMP_ROOT/missing-prompt/harnesses/pi"
make_temp_dispatch "$TEST2_HARNESS"
mkdir -p "$TMP_ROOT/missing-prompt/project"

stderr_file="$TMP_ROOT/stderr-2.txt"
rc=0
PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="test-model" \
    CODEGEN_BUILD_EFFORT="low" \
    CODEGEN_BUILD_NON_INTERACTIVE=1 \
    CODEGEN_BUILD_CWD="$TMP_ROOT/missing-prompt/project" \
    "$TEST2_HARNESS/dispatch.sh" "hello prompt" >"$stderr_file" 2>&1 || rc=$?

assert_eq "missing prompt exits 2" "2" "$rc"
stderr_content="$(cat "$stderr_file")"
assert_contains "missing prompt stderr mentions system prompt file" "$stderr_content" "system prompt file not found"

# ── Test 3: env-isolation — provider keys stripped before exec (loop path) ────
MIX_ARGS_FILE_3="$TMP_ROOT/mix-args-3.txt"
rc=0
TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_3" \
    PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_MODEL="test-model" \
    CODEGEN_BUILD_EFFORT="low" \
    CODEGEN_BUILD_NON_INTERACTIVE=1 \
    CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
    OPENAI_API_KEY=leak1 \
    ANTHROPIC_API_KEY=leak2 \
    CURSOR_API_KEY=leak3 \
    "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
    >/dev/null 2>&1 || rc=$?

assert_eq "env-isolation: loop path exit 0" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE_3" ]]; then
    ENV_OUT="$(cat "$MIX_ARGS_FILE_3")"
    assert_not_contains "env-isolation: OPENAI_API_KEY not in loop exec env" "$ENV_OUT" "OPENAI_API_KEY"
    assert_not_contains "env-isolation: ANTHROPIC_API_KEY not in loop exec env" "$ENV_OUT" "ANTHROPIC_API_KEY"
    assert_not_contains "env-isolation: CURSOR_API_KEY not in loop exec env" "$ENV_OUT" "CURSOR_API_KEY"
else
    printf 'FAIL: env-isolation — mix args file missing\n'
    fail=$((fail + 1))
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
