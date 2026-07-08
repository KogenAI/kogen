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
    if grep -Fq -- "$needle" <<<"$haystack" 2>/dev/null; then
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
    if grep -Fq -- "$needle" <<<"$haystack" 2>/dev/null; then
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

# Fake mix stub — dispatch.sh always execs `mix codegen.loop`. Stub it so
# these hermetic tests never invoke a real LLM/ExUnit round-trip; capture
# argv + env for assertions.
cat >"$FAKE_BIN/mix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${TARGET_MIX_ARGS_FILE:-/dev/null}"
env >> "${TARGET_MIX_ARGS_FILE:-/dev/null}"
exit 0
STUB
chmod +x "$FAKE_BIN/mix"

# Passing codegen-log stub — dispatch.sh preflights `codegen-log --version`
# before spawning any role. Without this stub, every exec-path case below
# would break (codegen-log absent from PATH -> preflight abort).
printf '#!/usr/bin/env bash\nprintf "codegen-log root=resolved\\n"\nexit 0\n' >"$FAKE_BIN/codegen-log"
chmod +x "$FAKE_BIN/codegen-log"

make_temp_dispatch() {
    local root="$1"
    mkdir -p "$root"
    cp "$DISPATCH" "$root/dispatch.sh"
    chmod +x "$root/dispatch.sh"
}

# ── Test 1: loop execs mix codegen.loop ───────────────────────────────────────
TEST1_HARNESS="$TMP_ROOT/harnesses/pi"
make_temp_dispatch "$TEST1_HARNESS"
mkdir -p "$TMP_ROOT/project"

MIX_ARGS_FILE_1="$TMP_ROOT/mix-args-1.txt"
rc=0
TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_1" \
    PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_STACK=phoenix \
    CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
    "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
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

# ── Test 2: missing test_harness/ dir → exit 2 (fail loud, no silent fallback) ──
TEST2_HARNESS="$TMP_ROOT/no-loop-dir/harnesses/pi"
make_temp_dispatch "$TEST2_HARNESS"
FAKE_CODEGEN_NO_LOOP="$TMP_ROOT/fake-codegen-no-loop"
mkdir -p "$FAKE_CODEGEN_NO_LOOP/harnesses/pi"
cp "$TEST2_HARNESS/dispatch.sh" "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/dispatch.sh"
mkdir -p "$TMP_ROOT/no-loop-dir/project"

rc=0
out=$(
    PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_NO_LOOP" \
        CODEGEN_BUILD_STACK=phoenix \
        CODEGEN_BUILD_CWD="$TMP_ROOT/no-loop-dir/project" \
        "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "missing test_harness/ dir: exit code 2" "2" "$rc"
assert_contains "missing test_harness/ dir: stderr mentions 'orchestration loop dir not found'" \
    "$out" "orchestration loop dir not found"

# ── Test 3: env-isolation — provider keys stripped before exec (loop path) ────
MIX_ARGS_FILE_3="$TMP_ROOT/mix-args-3.txt"
rc=0
TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_3" \
    PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_STACK=phoenix \
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

# ── Test 4: CODEGEN_BUILD_STACK unset/empty → exit 2 ──────────────────────────
# Regression lock: dispatch.sh must NOT silently coerce an empty/unset stack
# to "phoenix" — it must fail loud naming CODEGEN_BUILD_STACK.
# env -i (not just omitting the var) — guarantees CODEGEN_BUILD_STACK is truly
# absent regardless of the CALLER's ambient environment (a prior make-test
# fixture or manual export in the same shell can otherwise leak it through).
MIX_ARGS_FILE_4="$TMP_ROOT/mix-args-4.txt"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_4" \
        PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
        "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "missing CODEGEN_BUILD_STACK: exit code 2" "2" "$rc"
assert_contains "missing CODEGEN_BUILD_STACK: stderr names CODEGEN_BUILD_STACK" \
    "$out" "CODEGEN_BUILD_STACK is required but empty/unset"
if [[ -f "$MIX_ARGS_FILE_4" ]]; then
    printf 'FAIL: missing CODEGEN_BUILD_STACK — mix must NOT have been invoked\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# ── Test 5: codegen-log preflight — broken/absent codegen-log aborts loud,
# before any role spawns (assert exec-not-reached via the mix-args-file
# shimmed-subprocess marker, same pattern used by Test 4). ─────────────────
FAKE_BIN_BROKEN_LOG="$TMP_ROOT/bin-broken-log"
mkdir -p "$FAKE_BIN_BROKEN_LOG"
cp "$FAKE_BIN/mix" "$FAKE_BIN_BROKEN_LOG/mix"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN_BROKEN_LOG/codegen-log"
chmod +x "$FAKE_BIN_BROKEN_LOG/codegen-log"

MIX_ARGS_FILE_5="$TMP_ROOT/mix-args-5.txt"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_5" \
        PATH="$FAKE_BIN_BROKEN_LOG:$PATH" \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_STACK=phoenix \
        CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
        "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "broken codegen-log: exit code non-zero (2)" "2" "$rc"
assert_contains "broken codegen-log: stderr names codegen-log unresolvable" "$out" "codegen-log unresolvable"
assert_contains "broken codegen-log: stderr suggests make install" "$out" "make install"
if [[ -f "$MIX_ARGS_FILE_5" ]]; then
    printf 'FAIL: broken codegen-log — mix must NOT have been invoked (preflight must abort before exec)\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
