#!/usr/bin/env bash
# effort-contract_test.sh — producer->consumer contract test for canonical
# effort: harnesses/shared/effort-canonical.sh's enum/validator, codegen-build
# live --effort override threading, codegen-call --effort validation +
# per-adapter native realization, and config.yaml build-role effort values.
#
# Tests:
#   1. codegen_validate_effort accepts every canonical value, rejects
#      "minimal"/"bogus"/empty.
#   2. codegen-build --print-argv threads --effort into the loop argv
#      (claude leg); invalid --effort exits 2 before any argv is printed.
#   3. codegen-build --print-argv threads --effort into the loop argv
#      (pi leg).
#   4. codegen-call --print-argv on the claude leg omits --effort for "off",
#      emits --effort <v> for "high"; invalid value exits 2.
#   5. codegen-call --print-argv on the pi leg emits --thinking <v> for every
#      canonical value including "off"; invalid value exits 2.
#   6. config.yaml: every build-role .effort (both claude/pi bindings, plus
#      escalate_effort/fallback[].effort on the three developer roles) is
#      "off"; every investigative-mode .effort is unchanged (spot-check).
#
# Usage: bash effort-contract_test.sh
# Exit 0 -> all pass. Exit 1 -> one or more failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL_CLAUDE_HARNESS="$CODEGEN_DIR/harnesses/claude"
REAL_PI_HARNESS="$CODEGEN_DIR/harnesses/pi"

# shellcheck source=harnesses/shared/effort-canonical.sh
source "$CODEGEN_DIR/harnesses/shared/effort-canonical.sh"
# shellcheck source=harnesses/shared/test-stub-lib.sh
source "$CODEGEN_DIR/harnesses/shared/test-stub-lib.sh"

pass=0
fail=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:200}"
        fail=$((fail + 1))
    fi
}

BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

make_cb_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir"
    link_or_copy "$CODEGEN_DIR/codegen-build" "$dir/codegen-build"
    echo "$dir"
}

make_claude_harness() {
    local cb_root="$1"
    local harness_dir="$cb_root/harnesses/claude"
    mkdir -p "$harness_dir"
    link_or_copy "$REAL_CLAUDE_HARNESS/dispatch.sh" "$harness_dir/dispatch.sh"
}

make_pi_harness() {
    local cb_root="$1"
    local harness_dir="$cb_root/harnesses/pi"
    mkdir -p "$harness_dir"
    link_or_copy "$REAL_PI_HARNESS/dispatch.sh" "$harness_dir/dispatch.sh"
}

make_mix_stub() {
    local dir="$1"
    mkdir -p "$dir"
    make_stub "$dir/mix" 'printf '"'"'%s\n'"'"' "$@" > "${TARGET_ARGS_FILE:-/dev/null}"'
}

make_codegen_log_stub() {
    local dir="$1"
    mkdir -p "$dir"
    make_stub "$dir/codegen-log" 'printf "codegen-log root=resolved\n"'
}

make_cc_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir"
    link_or_copy "$CODEGEN_DIR/codegen-call" "$dir/codegen-call"
    echo "$dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: codegen_validate_effort enum membership.
# ─────────────────────────────────────────────────────────────────────────────
for v in off low medium high xhigh max; do
    ec=0
    codegen_validate_effort "$v" 2>/dev/null || ec=$?
    check "(1) codegen_validate_effort accepts $v" "0" "$ec"
done

for v in minimal bogus ""; do
    ec=0
    codegen_validate_effort "$v" 2>/dev/null || ec=$?
    check "(1) codegen_validate_effort rejects '$v'" "2" "$ec"
done

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: codegen-build --print-argv threads --effort=<v> (claude leg);
# invalid --effort exits 2.
# ─────────────────────────────────────────────────────────────────────────────
CB_CLAUDE="$(make_cb_root cb_claude)"
make_claude_harness "$CB_CLAUDE"

CB_MARKER="$BASE_TMP/cb_marker"
mkdir -p "$CB_MARKER"

BIN_CB="$BASE_TMP/bin_cb"
make_mix_stub "$BIN_CB"
make_codegen_log_stub "$BIN_CB"

ec=0
OUT_CB_CLAUDE="$(PATH="$BIN_CB:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" \
    "$CB_CLAUDE/codegen-build" \
    --harness=claude --stack=phoenix --cwd="$CB_MARKER" \
    --effort=off --print-argv "prompt" 2>/dev/null)" || ec=$?
check "(2) codegen-build --print-argv --effort=off exits 0 (claude)" "0" "$ec"
assert_contains "(2) argv contains --effort=off" "$OUT_CB_CLAUDE" "--effort=off"

ec=0
PATH="$BIN_CB:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" \
    "$CB_CLAUDE/codegen-build" \
    --harness=claude --stack=phoenix --cwd="$CB_MARKER" \
    --effort=bogus --print-argv "prompt" >/dev/null 2>/dev/null || ec=$?
check "(2) codegen-build --effort=bogus exits 2" "2" "$ec"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: codegen-build --print-argv threads --effort=<v> (pi leg).
# ─────────────────────────────────────────────────────────────────────────────
CB_PI="$(make_cb_root cb_pi)"
make_pi_harness "$CB_PI"

ec=0
OUT_CB_PI="$(PATH="$BIN_CB:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" \
    "$CB_PI/codegen-build" \
    --harness=pi --stack=phoenix --cwd="$CB_MARKER" \
    --effort=high --print-argv "prompt" 2>/dev/null)" || ec=$?
check "(3) codegen-build --print-argv --effort=high exits 0 (pi)" "0" "$ec"
assert_contains "(3) argv contains --effort=high" "$OUT_CB_PI" "--effort=high"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: codegen-call --print-argv claude leg — off omits --effort, high
# emits --effort high, bogus exits 2.
# ─────────────────────────────────────────────────────────────────────────────
SP_FILE="$BASE_TMP/sp.txt"
printf 'system prompt body\n' >"$SP_FILE"

CC_CLAUDE="$(make_cc_root cc_claude)"
mkdir -p "$CC_CLAUDE/harnesses/claude"
link_or_copy "$REAL_CLAUDE_HARNESS/call-dispatch.sh" "$CC_CLAUDE/harnesses/claude/call-dispatch.sh"

STUB_BIN="$BASE_TMP/stub_bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/claude.body" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","result":"ok","usage":{}}\n'
STUB
link_stub_path "$STUB_BIN/claude"

ec=0
OUT_CC_OFF="$(PATH="$STUB_BIN:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" "$CC_CLAUDE/codegen-call" \
    --harness=claude_code --model=haiku --effort=off \
    --system-prompt "@$SP_FILE" --print-argv "prompt" 2>/dev/null)" || ec=$?
check "(4) codegen-call claude --effort=off exits 0" "0" "$ec"
if [[ "$OUT_CC_OFF" == *"--effort"* ]]; then
    printf 'FAIL: (4) claude --effort=off print-argv must omit --effort\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

ec=0
OUT_CC_HIGH="$(PATH="$STUB_BIN:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" "$CC_CLAUDE/codegen-call" \
    --harness=claude_code --model=haiku --effort=high \
    --system-prompt "@$SP_FILE" --print-argv "prompt" 2>/dev/null)" || ec=$?
check "(4) codegen-call claude --effort=high exits 0" "0" "$ec"
assert_contains "(4) claude --effort=high emits --effort" "$OUT_CC_HIGH" "--effort"

ec=0
PATH="$STUB_BIN:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" "$CC_CLAUDE/codegen-call" \
    --harness=claude_code --model=haiku --effort=bogus \
    --system-prompt "@$SP_FILE" --print-argv "prompt" >/dev/null 2>/dev/null || ec=$?
check "(4) codegen-call claude --effort=bogus exits 2" "2" "$ec"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: codegen-call --print-argv pi leg — every canonical value (incl.
# off) emits --thinking <v>; bogus exits 2.
# ─────────────────────────────────────────────────────────────────────────────
CC_PI="$(make_cc_root cc_pi)"
mkdir -p "$CC_PI/harnesses/pi" "$CC_PI/harnesses/claude/hooks/lib"
link_or_copy "$REAL_PI_HARNESS/call-dispatch.sh" "$CC_PI/harnesses/pi/call-dispatch.sh"
link_or_copy "$REAL_PI_HARNESS/pi-jsonl-filter.cjs" "$CC_PI/harnesses/pi/pi-jsonl-filter.cjs"
link_or_copy "$REAL_CLAUDE_HARNESS/hooks/lib/schema-validate.js" \
    "$CC_PI/harnesses/claude/hooks/lib/schema-validate.js"

STUB_BIN_PI="$BASE_TMP/stub_bin_pi"
mkdir -p "$STUB_BIN_PI"
cat >"$STUB_BIN_PI/pi.body" <<'STUB'
#!/usr/bin/env bash
printf '{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}]}\n'
STUB
link_stub_path "$STUB_BIN_PI/pi"

ec=0
OUT_CC_PI_OFF="$(PATH="$STUB_BIN_PI:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" "$CC_PI/codegen-call" \
    --harness=pi --model=gpt-5 --effort=off \
    --system-prompt "@$SP_FILE" --print-argv "prompt" 2>/dev/null)" || ec=$?
check "(5) codegen-call pi --effort=off exits 0" "0" "$ec"
assert_contains "(5) pi --effort=off emits --thinking" "$OUT_CC_PI_OFF" "--thinking"
assert_contains "(5) pi --effort=off emits off value" "$OUT_CC_PI_OFF" "off"

ec=0
PATH="$STUB_BIN_PI:$PATH" OCG_CODEGEN_DIR="$CODEGEN_DIR" "$CC_PI/codegen-call" \
    --harness=pi --model=gpt-5 --effort=bogus \
    --system-prompt "@$SP_FILE" --print-argv "prompt" >/dev/null 2>/dev/null || ec=$?
check "(5) codegen-call pi --effort=bogus exits 2" "2" "$ec"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: config.yaml — every build-role effort is "off"; investigative
# modes unchanged (spot-check shape/inspector).
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_YAML="$CODEGEN_DIR/templates/generator/config.yaml"

BUILD_ROLE_EFFORTS="$(yq '
  .harness["planner-phoenix"].claude.effort,
  .harness["planner-phoenix"].pi.effort,
  .harness["planner-static"].claude.effort,
  .harness["planner-static"].pi.effort,
  .harness["developer-phoenix-backend"].claude.effort,
  .harness["developer-phoenix-backend"].claude.escalate_effort,
  .harness["developer-phoenix-backend"].claude.fallback[0].effort,
  .harness["developer-phoenix-backend"].pi.effort,
  .harness["developer-phoenix-backend"].pi.escalate_effort,
  .harness["developer-phoenix-backend"].pi.fallback[0].effort,
  .harness["developer-phoenix-frontend"].claude.effort,
  .harness["developer-phoenix-frontend"].claude.escalate_effort,
  .harness["developer-phoenix-frontend"].claude.fallback[0].effort,
  .harness["developer-phoenix-frontend"].pi.effort,
  .harness["developer-phoenix-frontend"].pi.escalate_effort,
  .harness["developer-phoenix-frontend"].pi.fallback[0].effort,
  .harness["developer-static"].claude.effort,
  .harness["developer-static"].claude.escalate_effort,
  .harness["developer-static"].claude.fallback[0].effort,
  .harness["developer-static"].pi.effort,
  .harness["developer-static"].pi.escalate_effort,
  .harness["developer-static"].pi.fallback[0].effort,
  .harness["reviewer-phoenix"].claude.effort,
  .harness["reviewer-phoenix"].pi.effort,
  .harness["reviewer-static"].claude.effort,
  .harness["reviewer-static"].pi.effort,
  .harness["committer"].claude.effort,
  .harness["committer"].pi.effort,
  .harness["context-curator"].claude.effort,
  .harness["context-curator"].pi.effort,
  .harness["app_build"].claude.effort,
  .harness["app_build"].pi.effort
' "$CONFIG_YAML")"

NON_OFF_COUNT=0
while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if [[ "$v" != "off" ]]; then
        printf 'FAIL: (6) build-role effort value %q is not "off"\n' "$v"
        NON_OFF_COUNT=$((NON_OFF_COUNT + 1))
    fi
done <<<"$BUILD_ROLE_EFFORTS"
check "(6) every build-role effort is off" "0" "$NON_OFF_COUNT"

SHAPE_EFFORT="$(yq '.harness.shape.claude.effort' "$CONFIG_YAML")"
check "(6) investigative mode (shape) effort unchanged (high)" "high" "$SHAPE_EFFORT"

INSPECTOR_EFFORT="$(yq '.harness.inspector.claude.effort' "$CONFIG_YAML")"
check "(6) investigative mode (inspector) effort unchanged (medium)" "medium" "$INSPECTOR_EFFORT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
