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

make_temp_dispatch() {
    local root="$1"
    mkdir -p "$root"
    cp "$DISPATCH" "$root/dispatch.sh"
    cp "$CODEGEN_ROOT/harnesses/pi/manifest.yaml" "$root/manifest.yaml"
    chmod +x "$root/dispatch.sh"
}

# ── Test 1: generated system prompt + default extensions + additive caller extension ──
TEST1_HARNESS="$TMP_ROOT/harnesses/pi"
make_temp_dispatch "$TEST1_HARNESS"
printf 'generated build prompt sentinel\n' >"$TEST1_HARNESS/pi-build-system-prompt.txt"
mkdir -p "$TMP_ROOT/project"

ARGS_FILE="$TMP_ROOT/args-1.txt"
rc=0
TARGET_ARGS_FILE="$ARGS_FILE" \
PATH="$FAKE_BIN:$PATH" \
OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
CODEGEN_BUILD_MODEL="test-model" \
CODEGEN_BUILD_EFFORT="low" \
CODEGEN_BUILD_NON_INTERACTIVE=1 \
CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
"$TEST1_HARNESS/dispatch.sh" --extension "$TMP_ROOT/custom-extension" "hello prompt" \
    >/dev/null 2>&1 || rc=$?

assert_eq "generated prompt + default extensions exit 0" "0" "$rc"
if [[ -f "$ARGS_FILE" ]]; then
    ARGS_CONTENT="$(cat "$ARGS_FILE")"
    assert_contains "system prompt flag present" "$ARGS_CONTENT" "--system-prompt"
    assert_contains "generated prompt passed" "$ARGS_CONTENT" "generated build prompt sentinel"
    assert_contains "default askuserquestion extension passed" "$ARGS_CONTENT" "$CODEGEN_ROOT/harnesses/pi/pi-extensions/askuserquestion"
    assert_contains "default subagents extension passed" "$ARGS_CONTENT" "$CODEGEN_ROOT/harnesses/pi/pi-extensions/subagents"
    assert_contains "default enforcement extension passed" "$ARGS_CONTENT" "$CODEGEN_ROOT/harnesses/pi/pi-extensions/enforcement"
    assert_contains "caller extension preserved" "$ARGS_CONTENT" "$TMP_ROOT/custom-extension"
    assert_contains "prompt forwarded" "$ARGS_CONTENT" "hello prompt"
else
    printf 'FAIL: generated prompt + default extensions — args file missing\n'
    fail=$((fail + 1))
fi

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

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
