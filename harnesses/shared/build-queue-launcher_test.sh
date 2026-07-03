#!/usr/bin/env bash
# build-queue-launcher_test.sh — unit tests for the --queue engine-selection
# branch in claude-build.sh / pi-build.sh.
#
# Engine selection mirrors dispatch.sh's CODEGEN_BUILD_ELIXIR gate:
#   --queue (no --elixir)  → legacy harnesses/shared/build-queue.sh drainer
#   --elixir --queue       → mix codegen.loop.queue (Elixir drain)
#
# Tests:
#  (1) claude --queue (no --elixir)     → build-queue.sh invoked, mix NOT invoked
#  (2) claude --elixir --queue          → mix codegen.loop.queue invoked, build-queue.sh NOT
#  (3) pi --queue                       → build-queue.sh invoked, mix NOT
#  (4) pi --elixir --queue              → mix invoked, build-queue.sh NOT
#  (5) legacy arm, build-queue.sh MISSING → exit non-zero + stderr contains OCG_CODEGEN_DIR hint
#  (6) --queue foo (extra slug arg)     → exit 1 usage error (both harnesses)
#  (7) Elixir arm, test_harness/ MISSING → exit 2 (existing guard preserved)

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
REAL_CLAUDE_BUILD="$CODEGEN_ROOT/harnesses/claude/claude-build.sh"
REAL_PI_BUILD="$CODEGEN_ROOT/harnesses/pi/pi-build.sh"

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
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:300}"
        fail=$((fail + 1))
    fi
}

assert_file_absent() {
    local desc="$1"
    local path="$2"
    if [[ ! -f "$path" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected absent, found: %s\n' "$desc" "$(cat "$path")"
        fail=$((fail + 1))
    fi
}

# ── Temp workspace ────────────────────────────────────────────────────────────
BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

make_stub() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

# make_ocg_root <name> — builds an isolated OCG_CODEGEN_DIR with a real copy of
# claude-build.sh/pi-build.sh under harnesses/{claude,pi}/, plus stub `mix` and
# stub build-queue.sh that each record invocation to a marker file.
make_ocg_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir/harnesses/claude" "$dir/harnesses/pi" "$dir/harnesses/shared" "$dir/bin"
    cp "$REAL_CLAUDE_BUILD" "$dir/harnesses/claude/claude-build.sh"
    chmod +x "$dir/harnesses/claude/claude-build.sh"
    cp "$REAL_PI_BUILD" "$dir/harnesses/pi/pi-build.sh"
    chmod +x "$dir/harnesses/pi/pi-build.sh"
    echo "$dir"
}

MIX_MARKER=""
BQ_MARKER=""

install_mix_stub() {
    local dir="$1"
    MIX_MARKER="$dir/mix-invoked.txt"
    make_stub "$dir/bin/mix" 'printf "%s\n" "$@" > "'"$MIX_MARKER"'"; exit 0'
}

install_build_queue_stub() {
    local dir="$1"
    BQ_MARKER="$dir/build-queue-invoked.txt"
    make_stub "$dir/harnesses/shared/build-queue.sh" 'printf "%s\n" "$@" > "'"$BQ_MARKER"'"; exit 0'
}

# ─────────────────────────────────────────────────────────────────────────────
# Test (1): claude --queue (no --elixir) → build-queue.sh invoked, mix NOT
# ─────────────────────────────────────────────────────────────────────────────
D1="$(make_ocg_root d1)"
install_mix_stub "$D1"
install_build_queue_stub "$D1"
FIXTURE_CWD_1="$BASE_TMP/cwd1"
mkdir -p "$FIXTURE_CWD_1"

ec1=0
(
    cd "$FIXTURE_CWD_1"
    OCG_CODEGEN_DIR="$D1" PATH="$D1/bin:$PATH" bash "$D1/harnesses/claude/claude-build.sh" --queue
) >"$BASE_TMP/out1.log" 2>&1 || ec1=$?

check "(1) claude --queue exits 0" "0" "$ec1"
if [[ -f "$BQ_MARKER" ]]; then
    assert_contains "(1) build-queue.sh got --harness=claude" "$(cat "$BQ_MARKER")" "--harness=claude"
else
    printf 'FAIL: (1) build-queue.sh marker not created\n'
    fail=$((fail + 1))
fi
assert_file_absent "(1) mix NOT invoked" "$MIX_MARKER"

# ─────────────────────────────────────────────────────────────────────────────
# Test (2): claude --elixir --queue → mix codegen.loop.queue invoked, build-queue.sh NOT
# ─────────────────────────────────────────────────────────────────────────────
D2="$(make_ocg_root d2)"
install_mix_stub "$D2"
install_build_queue_stub "$D2"
mkdir -p "$D2/test_harness"
FIXTURE_CWD_2="$BASE_TMP/cwd2"
mkdir -p "$FIXTURE_CWD_2"

ec2=0
(
    cd "$FIXTURE_CWD_2"
    OCG_CODEGEN_DIR="$D2" PATH="$D2/bin:$PATH" bash "$D2/harnesses/claude/claude-build.sh" --elixir --queue
) >"$BASE_TMP/out2.log" 2>&1 || ec2=$?

check "(2) claude --elixir --queue exits 0" "0" "$ec2"
if [[ -f "$MIX_MARKER" ]]; then
    assert_contains "(2) mix got codegen.loop.queue" "$(cat "$MIX_MARKER")" "codegen.loop.queue"
    assert_contains "(2) mix got --harness=claude" "$(cat "$MIX_MARKER")" "--harness=claude"
else
    printf 'FAIL: (2) mix marker not created\n'
    fail=$((fail + 1))
fi
assert_file_absent "(2) build-queue.sh NOT invoked" "$BQ_MARKER"

# ─────────────────────────────────────────────────────────────────────────────
# Test (3): pi --queue → build-queue.sh invoked, mix NOT
# ─────────────────────────────────────────────────────────────────────────────
D3="$(make_ocg_root d3)"
install_mix_stub "$D3"
install_build_queue_stub "$D3"
FIXTURE_CWD_3="$BASE_TMP/cwd3"
mkdir -p "$FIXTURE_CWD_3"

ec3=0
(
    cd "$FIXTURE_CWD_3"
    OCG_CODEGEN_DIR="$D3" PATH="$D3/bin:$PATH" bash "$D3/harnesses/pi/pi-build.sh" --queue
) >"$BASE_TMP/out3.log" 2>&1 || ec3=$?

check "(3) pi --queue exits 0" "0" "$ec3"
if [[ -f "$BQ_MARKER" ]]; then
    assert_contains "(3) build-queue.sh got --harness=pi" "$(cat "$BQ_MARKER")" "--harness=pi"
else
    printf 'FAIL: (3) build-queue.sh marker not created\n'
    fail=$((fail + 1))
fi
assert_file_absent "(3) mix NOT invoked" "$MIX_MARKER"

# ─────────────────────────────────────────────────────────────────────────────
# Test (4): pi --elixir --queue → mix invoked, build-queue.sh NOT
# ─────────────────────────────────────────────────────────────────────────────
D4="$(make_ocg_root d4)"
install_mix_stub "$D4"
install_build_queue_stub "$D4"
mkdir -p "$D4/test_harness"
FIXTURE_CWD_4="$BASE_TMP/cwd4"
mkdir -p "$FIXTURE_CWD_4"

ec4=0
(
    cd "$FIXTURE_CWD_4"
    OCG_CODEGEN_DIR="$D4" PATH="$D4/bin:$PATH" bash "$D4/harnesses/pi/pi-build.sh" --elixir --queue
) >"$BASE_TMP/out4.log" 2>&1 || ec4=$?

check "(4) pi --elixir --queue exits 0" "0" "$ec4"
if [[ -f "$MIX_MARKER" ]]; then
    assert_contains "(4) mix got codegen.loop.queue" "$(cat "$MIX_MARKER")" "codegen.loop.queue"
    assert_contains "(4) mix got --harness=pi" "$(cat "$MIX_MARKER")" "--harness=pi"
else
    printf 'FAIL: (4) mix marker not created\n'
    fail=$((fail + 1))
fi
assert_file_absent "(4) build-queue.sh NOT invoked" "$BQ_MARKER"

# ─────────────────────────────────────────────────────────────────────────────
# Test (5): legacy arm, build-queue.sh MISSING → exit non-zero + stderr hint
# ─────────────────────────────────────────────────────────────────────────────
D5="$(make_ocg_root d5)"
install_mix_stub "$D5"
# Deliberately do NOT install build-queue.sh stub — dir exists, file absent.
FIXTURE_CWD_5="$BASE_TMP/cwd5"
mkdir -p "$FIXTURE_CWD_5"

ec5=0
stderr5=$(
    cd "$FIXTURE_CWD_5"
    OCG_CODEGEN_DIR="$D5" PATH="$D5/bin:$PATH" bash "$D5/harnesses/claude/claude-build.sh" --queue 2>&1
) || ec5=$?

check "(5) missing build-queue.sh exits non-zero" "2" "$ec5"
assert_contains "(5) stderr mentions OCG_CODEGEN_DIR" "$stderr5" "OCG_CODEGEN_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Test (6): --queue foo (extra slug arg) → exit 1 usage error (both harnesses)
# ─────────────────────────────────────────────────────────────────────────────
D6="$(make_ocg_root d6)"
install_mix_stub "$D6"
install_build_queue_stub "$D6"

ec6c=0
bash "$D6/harnesses/claude/claude-build.sh" --queue foo >/dev/null 2>"$BASE_TMP/stderr6c" || ec6c=$?
check "(6) claude --queue foo exits 1" "1" "$ec6c"
assert_contains "(6) claude usage error mentions slug" "$(cat "$BASE_TMP/stderr6c")" "slug"

ec6p=0
bash "$D6/harnesses/pi/pi-build.sh" --queue foo >/dev/null 2>"$BASE_TMP/stderr6p" || ec6p=$?
check "(6) pi --queue foo exits 1" "1" "$ec6p"
assert_contains "(6) pi usage error mentions slug" "$(cat "$BASE_TMP/stderr6p")" "slug"

# ─────────────────────────────────────────────────────────────────────────────
# Test (7): Elixir arm, test_harness/ MISSING → exit 2 (existing guard preserved)
# ─────────────────────────────────────────────────────────────────────────────
D7="$(make_ocg_root d7)"
install_mix_stub "$D7"
install_build_queue_stub "$D7"
# Deliberately do NOT create test_harness/ dir.

ec7=0
stderr7=$(bash "$D7/harnesses/claude/claude-build.sh" --elixir --queue 2>&1) || ec7=$?
check "(7) missing test_harness/ exits 2" "2" "$ec7"
assert_contains "(7) stderr mentions test_harness" "$stderr7" "test_harness"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
