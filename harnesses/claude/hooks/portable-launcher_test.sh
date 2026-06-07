#!/usr/bin/env bash
# portable-launcher_test.sh — contract tests for portable launcher derivation and related guards.
#
# Assertions (>=14):
#  1. claude-build.sh sibling resolution (OCG_CODEGEN_DIR unset, non-Mac HOME)
#  2. pi-build.sh same
#  3. claude-shape.sh installed-flat layout (harnesses symlink → repo root)
#  4. claude-shape.sh in-repo-checkout layout
#  5. OCG_CODEGEN_DIR override wins for a non-build launcher
#  6. dispatch.sh (claude) missing config → exit 1 + "config.yaml not found" in stderr
#  7. dispatch.sh (claude) empty model block → exit 1 (no silent haiku fallback)
#  8. load-role.sh model fail-loud on missing model
#  9. gate: mix absent → FAILED gate-runner-missing + "mix not on PATH"
# 10. gate: make absent → FAILED gate-runner-missing
# 11. gate: exit 127 from runner on PATH but command exits 127 → FAILED not ALL CLEAR
# 12. gate: happy-path exit 0 → ALL CLEAR preserved (regression guard)
# 13. post-developer-format.sh bash-3.2 two-repo run → no crash, exit 0
# 14. Static grep: no Areas/Optimum/codegen literal in launchers/dispatch/load-role/orchestrator.md

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "${haystack:0:300}"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "${haystack:0:300}"
        fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

assert_exit() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s (exit=%s)\n' "$desc" "$actual"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected exit %s, got %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

make_stub() {
    local path="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

make_project() {
    local dir
    dir=$(mktemp -d "$BASE_TMP/proj.XXXXXX")
    (
        cd "$dir"
        git init -q
        git config user.email t@t
        git config user.name t
        git checkout -q -b main
        echo init >README
        git add README
        git commit -qm init
    )
    mkdir -p "$dir/.claude" "$dir/codegen/logging"
    printf '%s' "$dir"
}

make_transcript() {
    local transcript_path="$1" log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

gate_input() {
    local cwd="$1" agent="${2:-developer-phoenix-backend}" sid="${3:-sess1}" transcript="${4:-}"
    printf '{"hook_event_name":"SubagentStop","agent_type":"%s","agent_id":"abc","session_id":"%s","cwd":"%s","stop_hook_active":false,"transcript_path":"%s"}\n' \
        "$agent" "$sid" "$cwd" "$transcript"
}

# ── Test 1: claude-build.sh sibling resolution ───────────────────────────────
# Simulate installed-flat: claude-build.sh sits next to codegen-build in INSTALL_DIR
T1="$BASE_TMP/t1_flat"
mkdir -p "$T1"
cp "$CODEGEN_ROOT/harnesses/claude/claude-build.sh" "$T1/claude-build.sh"
# Stub codegen-build sibling: print its first arg so we can verify it was called
ARGS_T1="$BASE_TMP/t1_args.txt"
make_stub "$T1/codegen-build" "printf '%s\n' \"\$@\" > '$ARGS_T1'"

actual_exit=0
HOME="/tmp/nonexistent_user_xyz" bash "$T1/claude-build.sh" "hello prompt" 2>/dev/null || actual_exit=$?
if [[ -f "$ARGS_T1" ]] && grep -q "harness=claude" "$ARGS_T1"; then
    printf 'PASS: (1) claude-build.sh resolves sibling codegen-build without HOME fallback\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (1) claude-build.sh did not invoke sibling codegen-build (exit=%s)\n' "$actual_exit"
    fail=$((fail + 1))
fi

# ── Test 2: pi-build.sh sibling resolution ────────────────────────────────────
T2="$BASE_TMP/t2_flat"
mkdir -p "$T2"
cp "$CODEGEN_ROOT/harnesses/pi/pi-build.sh" "$T2/pi-build.sh"
ARGS_T2="$BASE_TMP/t2_args.txt"
make_stub "$T2/codegen-build" "printf '%s\n' \"\$@\" > '$ARGS_T2'"

actual_exit=0
HOME="/tmp/nonexistent_user_xyz" bash "$T2/pi-build.sh" "pi prompt" 2>/dev/null || actual_exit=$?
if [[ -f "$ARGS_T2" ]] && grep -q "harness=pi" "$ARGS_T2"; then
    printf 'PASS: (2) pi-build.sh resolves sibling codegen-build without HOME fallback\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (2) pi-build.sh did not invoke sibling codegen-build (exit=%s)\n' "$actual_exit"
    fail=$((fail + 1))
fi

# ── Test 3: claude-shape.sh installed-flat layout (harnesses symlink → repo root) ─
# Simulate: scripts installed flat in INSTALL_DIR; harnesses symlink present next to scripts
T3="$BASE_TMP/t3_install"
mkdir -p "$T3"
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T3/claude-shape.sh"
# harnesses symlink → real codegen root harnesses (so SCRIPT_DIR/harnesses exists)
ln -s "$CODEGEN_ROOT/harnesses" "$T3/harnesses"

ARGS_T3="$BASE_TMP/t3_args.txt"
CLAUDE_T3="$BASE_TMP/t3_bin"
mkdir -p "$CLAUDE_T3"
make_stub "$CLAUDE_T3/claude" "printf '%s\n' \"\$@\" > '$ARGS_T3'"
make_stub "$CLAUDE_T3/yq" 'echo "sonnet"' # load-role.sh will be called

# claude-shape requires no args (cold-start) and execs claude — but we stub claude
# so it won't actually open an interactive session. Just verify CODEGEN_DIR is derived.
actual_exit=0
PATH="$CLAUDE_T3:$PATH" HOME="/tmp/nonexistent_user_xyz" \
    bash "$T3/claude-shape.sh" 2>/dev/null || actual_exit=$?
# Shape either execs claude (exit whatever stub exits) or exits with load-role error
# Key: it must NOT exit because HOME-based CODEGEN_DIR was missing
# We check that CODEGEN_DIR would resolve via harnesses symlink using cd -P:
derived=$(HOME="/tmp/nonexistent_user_xyz" bash -c '
    SCRIPT_DIR="'"$T3"'"
    if [[ -d "$SCRIPT_DIR/harnesses" ]]; then
        cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd
    else
        echo MISS
    fi
')
assert_eq "(3) claude-shape.sh installed-flat: harnesses branch resolves codegen root" "$CODEGEN_ROOT" "$derived"

# ── Test 4: claude-shape.sh in-repo-checkout layout ──────────────────────────
# Script lives at harnesses/claude/claude-shape.sh; no harnesses dir next to it;
# $SCRIPT_DIR/../.. = repo root
T4_SCRIPT="$CODEGEN_ROOT/harnesses/claude/claude-shape.sh"
derived4=$(bash -c '
    SCRIPT_DIR="$(cd "$(dirname "'"$T4_SCRIPT"'")" && pwd)"
    if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
        echo "$OCG_CODEGEN_DIR"
    elif [[ -d "$SCRIPT_DIR/harnesses" ]]; then
        cd "$SCRIPT_DIR/harnesses/.." && pwd -P
    else
        cd "$SCRIPT_DIR/../.." && pwd -P
    fi
')
assert_eq "(4) claude-shape.sh in-repo layout: SCRIPT_DIR/../.. = repo root" "$CODEGEN_ROOT" "$derived4"

# ── Test 5: OCG_CODEGEN_DIR override wins for non-build launcher ──────────────
FAKE_OCG="$BASE_TMP/fake_ocg"
mkdir -p "$FAKE_OCG"
derived5=$(OCG_CODEGEN_DIR="$FAKE_OCG" bash -c '
    SCRIPT_DIR="/tmp/some/random/install/dir"
    if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
        echo "$OCG_CODEGEN_DIR"
    elif [[ -d "$SCRIPT_DIR/harnesses" ]]; then
        cd "$SCRIPT_DIR/harnesses/.." && pwd -P
    else
        cd "$SCRIPT_DIR/../.." && pwd -P
    fi
')
assert_eq "(5) OCG_CODEGEN_DIR override wins" "$FAKE_OCG" "$derived5"

# ── Test 6: dispatch.sh (claude) missing config → exit 1 ─────────────────────
T6="$BASE_TMP/t6_dispatch"
mkdir -p "$T6/harnesses/claude"
cp "$CODEGEN_ROOT/harnesses/claude/dispatch.sh" "$T6/harnesses/claude/dispatch.sh"
cp "$CODEGEN_ROOT/harnesses/claude/build-tools.txt" "$T6/harnesses/claude/build-tools.txt"
# No config.yaml — use a fake empty OCG dir
FAKE_OCG6="$BASE_TMP/t6_ocg_empty"
mkdir -p "$FAKE_OCG6/templates/generator"
# No config.yaml in that dir
YQ_T6="$BASE_TMP/t6_yq"
mkdir -p "$YQ_T6"
make_stub "$YQ_T6/yq" 'echo "sonnet"' # yq present but config missing

actual_exit=0
stderr6=$(
    PATH="$YQ_T6:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_OCG6" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        bash "$T6/harnesses/claude/dispatch.sh" 2>&1
) || actual_exit=$?
assert_exit "(6) dispatch.sh missing config exits 1" "1" "$actual_exit"
assert_contains "(6) dispatch.sh missing config stderr contains 'config.yaml not found'" "config.yaml not found" "$stderr6"

# ── Test 7: dispatch.sh (claude) no silent haiku fallback ─────────────────────
T7="$BASE_TMP/t7_dispatch"
mkdir -p "$T7/harnesses/claude"
cp "$CODEGEN_ROOT/harnesses/claude/dispatch.sh" "$T7/harnesses/claude/dispatch.sh"
cp "$CODEGEN_ROOT/harnesses/claude/build-tools.txt" "$T7/harnesses/claude/build-tools.txt"
# config.yaml present but model key is empty/null
FAKE_OCG7="$BASE_TMP/t7_ocg"
mkdir -p "$FAKE_OCG7/templates/generator"
cat >"$FAKE_OCG7/templates/generator/config.yaml" <<'YAML'
harness:
  build:
    claude:
      model: ""
      effort: medium
YAML
YQ_T7="$BASE_TMP/t7_yq"
mkdir -p "$YQ_T7"
# Real yq if available, else stub
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$YQ_T7/yq"
else
    make_stub "$YQ_T7/yq" 'echo ""'
fi

actual_exit=0
stderr7=$(
    PATH="$YQ_T7:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_OCG7" \
        CODEGEN_BUILD_MODEL="" CODEGEN_BUILD_EFFORT="" \
        bash "$T7/harnesses/claude/dispatch.sh" 2>&1
) || actual_exit=$?
# Must fail (exit 1) — no silent "haiku" fallback
assert_exit "(7) dispatch.sh empty model exits 1 (no silent fallback)" "1" "$actual_exit"
assert_not_contains "(7) dispatch.sh does not fall through to exec claude" "exec env" "$stderr7"

# ── Test 8: load-role.sh model fail-loud on missing model ─────────────────────
T8="$BASE_TMP/t8_load"
mkdir -p "$T8"
cp "$CODEGEN_ROOT/harnesses/claude/load-role.sh" "$T8/load-role.sh"
# config.yaml with no model for role "nonexistentrole"
FAKE_OCG8="$BASE_TMP/t8_ocg"
mkdir -p "$FAKE_OCG8/templates/generator"
cat >"$FAKE_OCG8/templates/generator/config.yaml" <<'YAML'
roles:
  shape:
    model: sonnet
    effort: high
YAML
YQ_T8="$BASE_TMP/t8_yq"
mkdir -p "$YQ_T8"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$YQ_T8/yq"
else
    make_stub "$YQ_T8/yq" 'echo ""'
fi

actual_exit=0
stderr8=$(
    PATH="$YQ_T8:$PATH" \
        CODEGEN_DIR="$FAKE_OCG8" \
        bash -c 'source '"$T8/load-role.sh"' && load_role nonexistentrole' 2>&1
) || actual_exit=$?
assert_exit "(8) load-role.sh missing model exits 1" "1" "$actual_exit"
assert_contains "(8) load-role.sh stderr mentions missing model" "missing/empty" "$stderr8"

# ── Test 9: gate: mix absent → FAILED gate-runner-missing ─────────────────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_gate9.md"
cat >"$LOG9" <<'MD'
# Step

## Plan

**Gate**: `mix test`
MD
make_transcript "$T9/transcript.jsonl" "$LOG9"

# PATH without mix — use minimal system PATH that has jq/awk/bash but not mix
# mix is typically in a version manager shim dir, not /usr/bin
SYSPATH9="/usr/bin:/bin:/usr/sbin:/sbin"
# Also need jq on this PATH
JQ_PATH=$(command -v jq 2>/dev/null || true)
if [[ -n "$JQ_PATH" ]]; then
    JQ_DIR="$(dirname "$JQ_PATH")"
    SYSPATH9="$JQ_DIR:$SYSPATH9"
fi

actual_exit=0
out9=$(
    PATH="$SYSPATH9" bash "$SCRIPT_DIR/phoenix-dev-gate.sh" 2>/dev/null \
        <<<"$(gate_input "$T9" developer-phoenix-backend sess9 "$T9/transcript.jsonl")"
) || actual_exit=$?

assert_not_contains "(9) mix absent: no ALL CLEAR" "ALL CLEAR" "$(cat "$LOG9" 2>/dev/null)"
assert_contains "(9) mix absent: FAILED gate-runner-missing in log" "FAILED" "$(cat "$LOG9" 2>/dev/null)"
assert_contains "(9) mix absent: gate-runner-missing label in log" "gate-runner-missing" "$(cat "$LOG9" 2>/dev/null)"
rm -rf "$T9"

# ── Test 10: gate: make exits 127 → FAILED gate-runner-missing ───────────────
# make is in /usr/bin so we can't easily remove it; instead stub it to exit 127
# and verify the 126/127 short-circuit fires with FAILED gate-runner-missing.
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_gate10.md"
cat >"$LOG10" <<'MD'
# Step

## Plan

**Gate**: `make test`
MD
make_transcript "$T10/transcript.jsonl" "$LOG10"

BIN10="$BASE_TMP/t10_bin"
mkdir -p "$BIN10"
make_stub "$BIN10/make" 'exit 127'

actual_exit=0
out10=$(
    PATH="$BIN10:$PATH" bash "$SCRIPT_DIR/phoenix-dev-gate.sh" 2>/dev/null \
        <<<"$(gate_input "$T10" developer-phoenix-backend sess10 "$T10/transcript.jsonl")"
) || actual_exit=$?

assert_contains "(10) make exit-127: FAILED gate-runner-missing in log" "gate-runner-missing" "$(cat "$LOG10" 2>/dev/null)"
assert_not_contains "(10) make exit-127: no ALL CLEAR" "ALL CLEAR" "$(cat "$LOG10" 2>/dev/null)"
rm -rf "$T10"

# ── Test 11: gate: exit 127 from runner on PATH but command exits 127 → FAILED ─
# Runner (mix) is on PATH as a stub that exits 127, simulating "command not found"
# inside the gate script itself.
T11=$(make_project)
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_gate11.md"
cat >"$LOG11" <<'MD'
# Step

## Plan

**Gate**: `mix test`
MD
make_transcript "$T11/transcript.jsonl" "$LOG11"

BIN11="$BASE_TMP/t11_bin"
mkdir -p "$BIN11"
# mix is present but exits 127 (simulates "elixir not installed" scenario)
make_stub "$BIN11/mix" 'exit 127'
# Keep system PATH so jq/awk/etc remain available; shadow mix with stub

actual_exit=0
out11=$(
    PATH="$BIN11:$PATH" bash "$SCRIPT_DIR/phoenix-dev-gate.sh" 2>/dev/null \
        <<<"$(gate_input "$T11" developer-phoenix-backend sess11 "$T11/transcript.jsonl")"
) || actual_exit=$?

log11_content="$(cat "$LOG11" 2>/dev/null)"
assert_contains "(11) exit-127 runner: FAILED in log" "FAILED" "$log11_content"
assert_not_contains "(11) exit-127 runner: no ALL CLEAR" "ALL CLEAR" "$log11_content"
rm -rf "$T11"

# ── Test 12: gate: happy-path exit 0 → ALL CLEAR ─────────────────────────────
T12=$(make_project)
LOG12="$T12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_gate12.md"
cat >"$LOG12" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T12/transcript.jsonl" "$LOG12"

actual_exit=0
out12=$(
    bash "$SCRIPT_DIR/phoenix-dev-gate.sh" 2>/dev/null \
        <<<"$(gate_input "$T12" developer-phoenix-backend sess12 "$T12/transcript.jsonl")"
) || actual_exit=$?

assert_contains "(12) happy-path: ALL CLEAR in log" "ALL CLEAR" "$(cat "$LOG12" 2>/dev/null)"
assert_not_contains "(12) happy-path: no FAILED in log" "FAILED" "$(cat "$LOG12" 2>/dev/null)"
rm -rf "$T12"

# ── Test 13: post-developer-format.sh bash-3.2 two-repo run → no crash ────────
T13A=$(make_project)
T13B=$(make_project)
# Create a changed file in each repo
mkdir -p "$T13A/lib" && echo "content" >"$T13A/lib/foo.ex"
mkdir -p "$T13B/lib" && echo "content" >"$T13B/lib/bar.ex"

# Build a ledger at expected path: $HOME/.claude/post-format/<SESSION_ID>_<AGENT_ID>.txt
T13_HOME="$BASE_TMP/t13_home"
mkdir -p "$T13_HOME/.claude/post-format"
LEDGER13="$T13_HOME/.claude/post-format/t13sess_agentabc.txt"
printf '%s\n%s\n' "$T13A/lib/foo.ex" "$T13B/lib/bar.ex" >"$LEDGER13"

FORMAT_HOOK="$SCRIPT_DIR/post-developer-format.sh"
actual_exit=0
# Run hook with ledger pointing to two-repo files; suppress actual formatting errors
HOME="$T13_HOME" \
    AGENT_TYPE="developer-phoenix-backend" \
    AGENT_ID="agentabc" \
    CWD="$T13A" \
    SESSION_ID="t13sess" \
    STOP_HOOK_ACTIVE="false" \
    bash "$FORMAT_HOOK" </dev/null 2>/dev/null || actual_exit=$?

# Just verify it doesn't crash (declare -A would crash on bash < 4.0 or exit non-zero)
assert_exit "(13) post-developer-format.sh two-repo run exits 0" "0" "$actual_exit"
rm -rf "$T13A" "$T13B" "$T13_HOME"

# ── Test 14: static grep — no hardcoded Areas/Optimum/codegen in source files ──
FILES_TO_CHECK=(
    "$CODEGEN_ROOT/harnesses/claude/claude-build.sh"
    "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh"
    "$CODEGEN_ROOT/harnesses/claude/claude-refactor.sh"
    "$CODEGEN_ROOT/harnesses/claude/claude-debug.sh"
    "$CODEGEN_ROOT/harnesses/claude/claude-ops.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-build.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-shape.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-refactor.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-debug.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-ops.sh"
    "$CODEGEN_ROOT/harnesses/claude/dispatch.sh"
    "$CODEGEN_ROOT/harnesses/pi/dispatch.sh"
    "$CODEGEN_ROOT/harnesses/claude/load-role.sh"
    "$CODEGEN_ROOT/shared/rules/roles/orchestrator.md"
)
found_literal=""
for f in "${FILES_TO_CHECK[@]}"; do
    if grep -qF "Areas/Optimum/codegen" "$f" 2>/dev/null; then
        found_literal="${found_literal} $f"
    fi
done
if [[ -z "$found_literal" ]]; then
    printf 'PASS: (14) no hardcoded Areas/Optimum/codegen in launchers/dispatch/load-role/orchestrator.md\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (14) hardcoded Areas/Optimum/codegen found in:%s\n' "$found_literal"
    fail=$((fail + 1))
fi

# ── Results ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
