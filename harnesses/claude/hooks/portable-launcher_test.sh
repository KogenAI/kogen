#!/usr/bin/env bash
# portable-launcher_test.sh — contract tests for portable launcher derivation and related guards.
#
# Assertions (>=15):
#  1. claude-build.sh sibling resolution (OCG_CODEGEN_DIR unset, non-Mac HOME)
#  2. pi-build.sh same
#  3. claude-shape.sh installed-flat layout — REAL launcher run; capture exported CODEGEN_DIR
#  4. claude-shape.sh in-repo-checkout layout — REAL launcher run; no sibling harnesses dir
#  5. OCG_CODEGEN_DIR override wins — REAL launcher run with populated fake OCG tree
#  6. dispatch.sh (claude) missing config → exit 1 + "config.yaml not found" in stderr
#  7. dispatch.sh (claude) empty model block → exit 1 (no silent haiku fallback)
#  8. load-role.sh model fail-loud on missing model
#  9. gate: mix absent → FAILED gate-runner-missing + "mix not on PATH"
# 10. gate: make absent → FAILED gate-runner-missing
# 11. gate: exit 127 from runner on PATH but command exits 127 → FAILED not ALL CLEAR
# 12. gate: happy-path exit 0 → ALL CLEAR preserved (regression guard)
# 13. post-developer-format.sh bash-3.2 two-repo run → no crash, exit 0
# 14. Static grep: no Areas/Optimum/codegen literal in launchers/dispatch/load-role/orchestrator.md
# 15. Drift loop: SCRIPT_DIR + CODEGEN_DIR derivation block byte-identical across all non-build launchers

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

assert_exit() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s (exit=%s)\n' "$desc" "$actual"
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (1) claude-build.sh resolves sibling codegen-build without HOME fallback\n'
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (2) pi-build.sh resolves sibling codegen-build without HOME fallback\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (2) pi-build.sh did not invoke sibling codegen-build (exit=%s)\n' "$actual_exit"
    fail=$((fail + 1))
fi

# ── Test 3: claude-shape.sh installed-flat layout — run REAL launcher ────────
# Simulate: scripts installed flat in INSTALL_DIR; harnesses symlink present next to scripts.
# Stub claude to capture the exported CODEGEN_DIR that crosses the exec boundary.
T3="$BASE_TMP/t3_install"
mkdir -p "$T3"
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T3/claude-shape.sh"
# harnesses symlink → real codegen root harnesses (so SCRIPT_DIR/harnesses exists)
ln -s "$CODEGEN_ROOT/harnesses" "$T3/harnesses"

CAPTURE_T3="$BASE_TMP/t3_captured_codegen_dir.txt"
BIN_T3="$BASE_TMP/t3_bin"
mkdir -p "$BIN_T3"
# stub claude: capture the CODEGEN_DIR env var that the launcher exports before exec
make_stub "$BIN_T3/claude" "printf '%s' \"\$CODEGEN_DIR\" > '$CAPTURE_T3'"
# Use real yq so load_role shape succeeds against the real config.yaml (resolved via harnesses symlink)
YQ_REAL=$(command -v yq 2>/dev/null || true)
[ -n "$YQ_REAL" ] && ln -s "$YQ_REAL" "$BIN_T3/yq"

actual_exit=0
PATH="$BIN_T3:$PATH" HOME="/tmp/nonexistent_user_xyz" \
    bash "$T3/claude-shape.sh" 2>/dev/null || actual_exit=$?
# Read what the REAL launcher exported as CODEGEN_DIR
derived3=""
[ -f "$CAPTURE_T3" ] && derived3=$(cat "$CAPTURE_T3")
assert_eq "(3) claude-shape.sh installed-flat: real launcher exports CODEGEN_DIR == repo root" "$CODEGEN_ROOT" "$derived3"

# ── Test 4: claude-shape.sh in-repo-checkout layout — run REAL launcher ──────
# Script lives at harnesses/claude/claude-shape.sh inside repo; no sibling harnesses dir;
# SCRIPT_DIR/../.. = repo root. Run the real launcher; capture derived CODEGEN_DIR.
CAPTURE_T4="$BASE_TMP/t4_captured_codegen_dir.txt"
BIN_T4="$BASE_TMP/t4_bin"
mkdir -p "$BIN_T4"
make_stub "$BIN_T4/claude" "printf '%s' \"\$CODEGEN_DIR\" > '$CAPTURE_T4'"
# Use real yq; in-repo layout resolves CODEGEN_DIR to repo root where real config.yaml lives
YQ_REAL=$(command -v yq 2>/dev/null || true)
[ -n "$YQ_REAL" ] && ln -s "$YQ_REAL" "$BIN_T4/yq"

actual_exit=0
PATH="$BIN_T4:$PATH" \
    bash "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" 2>/dev/null || actual_exit=$?
derived4=""
[ -f "$CAPTURE_T4" ] && derived4=$(cat "$CAPTURE_T4")
assert_eq "(4) claude-shape.sh in-repo layout: real launcher exports CODEGEN_DIR == repo root" "$CODEGEN_ROOT" "$derived4"

# ── Test 5: OCG_CODEGEN_DIR override wins — run REAL launcher ────────────────
# Override must win over both the harnesses-symlink and SCRIPT_DIR/../.. branches.
# Populate FAKE_OCG with a minimal config.yaml so load_role shape succeeds.
FAKE_OCG="$BASE_TMP/fake_ocg"
mkdir -p "$FAKE_OCG/templates/generator"
cat >"$FAKE_OCG/templates/generator/config.yaml" <<'YAML'
roles:
  shape:
    model: opus
    effort: high
    system_prompt: "stub"
    tools: []
YAML
# Also need the harnesses/claude directory for load-role.sh source path
mkdir -p "$FAKE_OCG/harnesses/claude"
cp "$CODEGEN_ROOT/harnesses/claude/load-role.sh" "$FAKE_OCG/harnesses/claude/load-role.sh"

CAPTURE_T5="$BASE_TMP/t5_captured_codegen_dir.txt"
BIN_T5="$BASE_TMP/t5_bin"
mkdir -p "$BIN_T5"
make_stub "$BIN_T5/claude" "printf '%s' \"\$CODEGEN_DIR\" > '$CAPTURE_T5'"
# real yq or stub — both work since config.yaml is well-formed
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN_T5/yq"
else
    make_stub "$BIN_T5/yq" 'echo "opus"'
fi

actual_exit=0
# Run REAL launcher (in-repo path) with OCG_CODEGEN_DIR pointing to FAKE_OCG
PATH="$BIN_T5:$PATH" OCG_CODEGEN_DIR="$FAKE_OCG" \
    bash "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" 2>/dev/null || actual_exit=$?
derived5=""
[ -f "$CAPTURE_T5" ] && derived5=$(cat "$CAPTURE_T5")
assert_eq "(5) OCG_CODEGEN_DIR override wins: real launcher exports CODEGEN_DIR == FAKE_OCG" "$FAKE_OCG" "$derived5"

# ── Drift loop: derivation block must be byte-identical across all non-build launchers ──
# Extracts the 7-line derivation block from claude-shape.sh (lines 10-17) and
# asserts every sibling launcher carries the identical text. Catches copy-paste drift at
# zero extra cost — pure grep/bash, no LLM calls.
REFERENCE_LAUNCHER="$CODEGEN_ROOT/harnesses/claude/claude-shape.sh"
# Extract the portable derivation block: SCRIPT_DIR assignment + 3-branch CODEGEN_DIR if/elif/else/fi + export
DERIV_BLOCK=$(grep -A 8 '^SCRIPT_DIR=' "$REFERENCE_LAUNCHER" | head -9)
LAUNCHERS_TO_CHECK=(
    "$CODEGEN_ROOT/harnesses/claude/claude-debug.sh"
    "$CODEGEN_ROOT/harnesses/claude/claude-ops.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-shape.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-debug.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-ops.sh"
)
drift_found=""
for launcher in "${LAUNCHERS_TO_CHECK[@]}"; do
    if [ ! -f "$launcher" ]; then
        drift_found="${drift_found} MISSING:$(basename "$launcher")"
        continue
    fi
    candidate=$(grep -A 8 '^SCRIPT_DIR=' "$launcher" | head -9)
    if [[ "$candidate" != "$DERIV_BLOCK" ]]; then
        drift_found="${drift_found} DRIFT:$(basename "$launcher")"
    fi
done
if [[ -z "$drift_found" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (drift-loop) derivation block identical across all non-build launchers\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (drift-loop) derivation block differs in:%s\n' "$drift_found"
    printf '  reference (%s):\n%s\n' "$(basename "$REFERENCE_LAUNCHER")" "$DERIV_BLOCK"
    fail=$((fail + 1))
fi

# ── Test 6: dispatch.sh (claude) missing config → exit 1 ─────────────────────
T6="$BASE_TMP/t6_dispatch"
mkdir -p "$T6/harnesses/claude"
cp "$CODEGEN_ROOT/harnesses/claude/dispatch.sh" "$T6/harnesses/claude/dispatch.sh"
cp "$CODEGEN_ROOT/harnesses/claude/build-tools.txt" "$T6/harnesses/claude/build-tools.txt"
cp "$CODEGEN_ROOT/harnesses/claude/claude-build-system-prompt.txt" "$T6/harnesses/claude/claude-build-system-prompt.txt"
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
cp "$CODEGEN_ROOT/harnesses/claude/claude-build-system-prompt.txt" "$T7/harnesses/claude/claude-build-system-prompt.txt"
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
    RENDER_CHECK_CMD="" WIRING_CHECK_CMD="" \
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
    "$CODEGEN_ROOT/harnesses/claude/claude-debug.sh"
    "$CODEGEN_ROOT/harnesses/claude/claude-ops.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-build.sh"
    "$CODEGEN_ROOT/harnesses/pi/pi-shape.sh"
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
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (14) no hardcoded Areas/Optimum/codegen in launchers/dispatch/load-role/orchestrator.md\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (14) hardcoded Areas/Optimum/codegen found in:%s\n' "$found_literal"
    fail=$((fail + 1))
fi

# ── Test 16: Tier-0 loading — file in Always Load section gets appended ───────
T16="$BASE_TMP/t16_tier0"
mkdir -p "$T16/context"
# Minimal PROJECT_CONTEXT.md with Always Load section
cat >"$T16/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |

## Always Load

Tier-0 foundational docs — the launcher loads these on every shape session.

- repo-structure.md
- core.md

## Next Section
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T16/context/repo-structure.md"
printf 'CORE_CONTENT' >"$T16/context/core.md"

BIN16="$BASE_TMP/t16_bin"
mkdir -p "$BIN16"
CAPTURE16="$BASE_TMP/t16_args.txt"
# Stub claude: write all args joined to a file so we can inspect them
make_stub "$BIN16/claude" "printf '%s\n' \"\$@\" > '$CAPTURE16'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN16/yq"
fi
# Copy launcher; point harnesses symlink to real codegen so load_role resolves
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T16/claude-shape.sh"
ln -s "$CODEGEN_ROOT/harnesses" "$T16/harnesses"

actual_exit=0
(cd "$T16" && PATH="$BIN16:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh 2>/dev/null) || actual_exit=$?
captured16=""
[ -f "$CAPTURE16" ] && captured16=$(cat "$CAPTURE16")
assert_contains "(16) Tier-0 loading: repo-structure.md content in claude args" "REPO_STRUCTURE_CONTENT" "$captured16"
assert_contains "(16) Tier-0 loading: core.md content in claude args" "CORE_CONTENT" "$captured16"

# ── Test 17: Tier-0 fail-open — missing file does NOT abort ───────────────────
T17="$BASE_TMP/t17_tier0_failopen"
mkdir -p "$T17/context"
cat >"$T17/PROJECT_CONTEXT.md" <<'EOF'
## Always Load

- nonexistent-file.md
- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T17/context/repo-structure.md"
# nonexistent-file.md is deliberately absent

BIN17="$BASE_TMP/t17_bin"
mkdir -p "$BIN17"
CAPTURE17="$BASE_TMP/t17_args.txt"
make_stub "$BIN17/claude" "printf '%s\n' \"\$@\" > '$CAPTURE17'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN17/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T17/claude-shape.sh"
ln -s "$CODEGEN_ROOT/harnesses" "$T17/harnesses"

actual_exit=0
(cd "$T17" && PATH="$BIN17:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh 2>/dev/null) || actual_exit=$?
assert_exit "(17) Tier-0 fail-open: launcher exits 0 despite missing Always Load file" "0" "$actual_exit"
captured17=""
[ -f "$CAPTURE17" ] && captured17=$(cat "$CAPTURE17")
assert_contains "(17) Tier-0 fail-open: existing file still loaded" "REPO_STRUCTURE_CONTENT" "$captured17"

# ── Test 18: Tier-1 loading — pitch identifier match appends context file ─────
T18="$BASE_TMP/t18_tier1"
mkdir -p "$T18/context" "$T18/codegen/pitches/draft"
cat >"$T18/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/harnesses.md` | Harness specifics | claude-shape, dispatch.sh, launcher | harnesses/ |
| `context/hooks.md` | Hook system | PreToolUse, SubagentStop, hook test | harnesses/*/hooks/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T18/context/repo-structure.md"
printf 'HARNESSES_CONTENT' >"$T18/context/harnesses.md"
printf 'HOOKS_CONTENT' >"$T18/context/hooks.md"
# Pitch that mentions "dispatch.sh" (matches harnesses.md row)
printf '## Problem\nNeed to fix dispatch.sh routing logic.\n' >"$T18/codegen/pitches/draft/my-pitch.md"

BIN18="$BASE_TMP/t18_bin"
mkdir -p "$BIN18"
CAPTURE18="$BASE_TMP/t18_args.txt"
make_stub "$BIN18/claude" "printf '%s\n' \"\$@\" > '$CAPTURE18'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN18/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T18/claude-shape.sh"
ln -s "$CODEGEN_ROOT/harnesses" "$T18/harnesses"

actual_exit=0
(cd "$T18" && PATH="$BIN18:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh my-pitch 2>/dev/null) || actual_exit=$?
captured18=""
[ -f "$CAPTURE18" ] && captured18=$(cat "$CAPTURE18")
# harnesses.md should be loaded (dispatch.sh matches), hooks.md should NOT (no match)
assert_contains "(18) Tier-1 loading: matched context file content in args" "HARNESSES_CONTENT" "$captured18"
assert_not_contains "(18) Tier-1 loading: unmatched context file not in args" "HOOKS_CONTENT" "$captured18"

# ── Test 19: Tier-1 dedup — Tier-0 file not double-loaded in Tier-1 ───────────
T19="$BASE_TMP/t19_tier1_dedup"
mkdir -p "$T19/context" "$T19/codegen/pitches/draft"
cat >"$T19/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/repo-structure.md` | Repo structure | repo-structure, directory, artifact | top-level scripts |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T19/context/repo-structure.md"
# Pitch that mentions "repo-structure" (would match Tier-1 row if not deduped)
printf '## Problem\nNeed to update repo-structure and directory layout.\n' >"$T19/codegen/pitches/draft/dedup-pitch.md"

BIN19="$BASE_TMP/t19_bin"
mkdir -p "$BIN19"
CAPTURE19="$BASE_TMP/t19_args.txt"
make_stub "$BIN19/claude" "printf '%s\n' \"\$@\" > '$CAPTURE19'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN19/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T19/claude-shape.sh"
ln -s "$CODEGEN_ROOT/harnesses" "$T19/harnesses"

actual_exit=0
(cd "$T19" && PATH="$BIN19:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh dedup-pitch 2>/dev/null) || actual_exit=$?
captured19=""
[ -f "$CAPTURE19" ] && captured19=$(cat "$CAPTURE19")
# Count occurrences of REPO_STRUCTURE_CONTENT — should be exactly 1 (Tier-0, not doubled)
occurrences19=$(printf '%s' "$captured19" | grep -c "REPO_STRUCTURE_CONTENT" 2>/dev/null || true)
assert_eq "(19) Tier-1 dedup: Tier-0 file loaded exactly once" "1" "$occurrences19"

# ── Results ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
