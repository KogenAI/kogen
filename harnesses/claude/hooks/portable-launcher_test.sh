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
#  9-12. (removed — phoenix-dev-gate.sh deleted under the orchestration-loop
#         cutover; gate-runner-missing/happy-path coverage now lives in
#         loop_gate_test.exs)
# 13. (removed — post-developer-format.sh deleted under the orchestration-loop
#      cutover; the loop runs an explicit format step instead)
# 14. Static grep: no Areas/Optimum/codegen literal in launchers/dispatch/load-role
# 15. Drift loop: SCRIPT_DIR + CODEGEN_DIR derivation block byte-identical across all non-build launchers
# 20. Bash 3.2 empty-array splat guard: every "${arr[@]}" full-splat in mode
#     launchers (claude-*.sh, pi-*.sh) must use the "${arr[@]+"${arr[@]}"}"
#     empty-safe idiom. Includes a self-check on a synthetic fixture so a
#     regression in the detection filter itself is caught.
# 22. pitch-context-selector.sh citation priority: an explicitly-cited
#     context/<name>.md row wins over an earlier keyword-only row.
# 23. cited-only beats keyword-only: a row cited by exact path but not
#     keyword-matched still outranks an earlier keyword-only row.
# 24. no-citation pitch selects the same first-six keyword rows in table
#     order as before the change (behavior-preservation).
# 25. cap warning names only the lower-priority losing rows.
# 26. missing selected file fails loud: non-zero exit, stderr names the
#     file, stub CLI never invoked.
# 27. all four production callers (claude-shape, claude-experiment,
#     pi-shape, pi-experiment) route through the same selector.

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
    thinking_tokens: 16000
    system_prompt: "stub"
    tools: []
YAML
# Also need the harnesses/claude directory for load-role.sh source path, and
# harnesses/shared for mode-context.sh (load-role.sh sources it)
mkdir -p "$FAKE_OCG/harnesses/claude" "$FAKE_OCG/harnesses/shared"
cp "$CODEGEN_ROOT/harnesses/claude/load-role.sh" "$FAKE_OCG/harnesses/claude/load-role.sh"
cp "$CODEGEN_ROOT/harnesses/shared/mode-context.sh" "$FAKE_OCG/harnesses/shared/mode-context.sh"
cp "$CODEGEN_ROOT/harnesses/shared/pitch-context-selector.sh" "$FAKE_OCG/harnesses/shared/pitch-context-selector.sh"

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

# Tests 9-12 (phoenix-dev-gate.sh gate-runner-missing/happy-path assertions)
# removed: phoenix-dev-gate.sh was deleted as part of the orchestration-loop
# cutover (Pass 1) — the deterministic Elixir loop (loop_gate.ex) now drives
# the gate, not a SubagentStop hook. Their coverage (runner-missing fail-loud,
# happy-path ALL CLEAR) is superseded by loop_gate_test.exs.

# Test 13 (post-developer-format.sh bash-3.2 two-repo run) removed:
# post-developer-format.sh was deleted as part of the orchestration-loop
# cutover — the loop runs an explicit format step (OrchestrationLoop.run_format_step/2)
# after the developer role instead of a SubagentStop fix-up hook.

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
)
found_literal=""
for f in "${FILES_TO_CHECK[@]}"; do
    if grep -qF "Areas/Optimum/codegen" "$f" 2>/dev/null; then
        found_literal="${found_literal} $f"
    fi
done
if [[ -z "$found_literal" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (14) no hardcoded Areas/Optimum/codegen in launchers/dispatch/load-role\n'
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

# ── Test 20: bash-3.2 empty-array splat guard across mode launchers ──────────
# Detection pipeline: find bare "${name[@]}" full-splats, excluding "${#..}"
# length-checks and the empty-safe "${arr[@]+"${arr[@]}"}" idiom.
splat_offenders() {
    local file="$1"
    grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}' "$file" 2>/dev/null | grep -vE '\$\{#|\[@\]\+' || true
}

# Self-check: guards the guard. A bare splat must be detected; a guarded one must not.
T20_FIXTURE="$BASE_TMP/t20_fixture.sh"
cat >"$T20_FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
Z="${C[@]}"
X=("${A[@]+"${A[@]}"}")
FIXTURE
t20_selfcheck_hits=$(splat_offenders "$T20_FIXTURE" | wc -l | tr -d ' ')
assert_eq "(20) self-check: detection pipeline flags exactly the bare splat, not the guarded one" "1" "$t20_selfcheck_hits"

# Invariant: glob-discover mode launchers; assert zero bare full-splats.
T20_LAUNCHERS=()
while IFS= read -r -d '' f; do
    T20_LAUNCHERS+=("$f")
done < <(find "$CODEGEN_ROOT/harnesses/claude" "$CODEGEN_ROOT/harnesses/pi" -maxdepth 1 \( -name 'claude-*.sh' -o -name 'pi-*.sh' \) -print0 2>/dev/null)

t20_offenders=""
for f in "${T20_LAUNCHERS[@]+"${T20_LAUNCHERS[@]}"}"; do
    hits=$(splat_offenders "$f")
    if [[ -n "$hits" ]]; then
        while IFS= read -r hit_line; do
            t20_offenders="${t20_offenders} $(basename "$f"):${hit_line%%:*}"
        done <<<"$hits"
    fi
done
if [[ -z "$t20_offenders" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (20) no bare empty-unsafe array splats in mode launchers\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (20) bare empty-unsafe array splats found in:%s\n' "$t20_offenders"
    fail=$((fail + 1))
fi

# ── Test 21: Required Platforms section composes with Always Load / Domain ────
# Fixture places a new "## Required Platforms" H2 BETWEEN "## Overview" and
# "## Domain Context Files" — the boundary the pitch commits to. Proves the
# whole-file append still forwards the field AND both parser-owned sections
# (Always Load / Domain table) still produce unchanged output, across all four
# PROJECT_CONTEXT-reading launchers (claude-shape, pi-shape, claude-experiment,
# pi-experiment).
T21="$BASE_TMP/t21_required_platforms"
mkdir -p "$T21/context" "$T21/codegen/pitches/draft"
cat >"$T21/PROJECT_CONTEXT.md" <<'EOF'
## Overview

- **What**: fixture project.

## Required Platforms

required_platforms: [darwin, linux]

## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/harnesses.md` | Harness specifics | claude-shape, dispatch.sh, launcher | harnesses/ |
| `context/hooks.md` | Hook system | PreToolUse, SubagentStop, hook test | harnesses/*/hooks/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T21/context/repo-structure.md"
printf 'HARNESSES_CONTENT' >"$T21/context/harnesses.md"
printf 'HOOKS_CONTENT' >"$T21/context/hooks.md"
printf '## Problem\nNeed to fix dispatch.sh routing logic.\n' >"$T21/codegen/pitches/draft/t21-pitch.md"

run_t21_launcher() {
    local launcher_src="$1" launcher_name="$2" stub_bin="$3" extra_args="$4"
    local target_dir="${5:-$T21}"
    local dst="$target_dir/$launcher_name"
    local run_tag
    run_tag="$(basename "$target_dir")_${launcher_name}"
    local capture="$BASE_TMP/${run_tag}_args.txt"
    local bindir="$BASE_TMP/${run_tag}_bin"
    mkdir -p "$bindir"
    make_stub "$bindir/$stub_bin" "printf '%s\n' \"\$@\" > '$capture'"
    if command -v yq >/dev/null 2>&1; then
        ln -s "$(command -v yq)" "$bindir/yq"
    fi
    cp "$launcher_src" "$dst"
    # -n: treat an existing symlink-to-dir as a file to replace, not a dir to
    # descend into. Without -n, the second call across repeated invocations
    # (the same target dir serves 4 separate launchers) resolves the existing
    # symlink and creates the new link INSIDE the target, producing a tracked
    # harnesses/harnesses artifact in the real repo. See t21-pitch fix.
    ln -sfn "$CODEGEN_ROOT/harnesses" "$target_dir/harnesses"
    (cd "$target_dir" && PATH="$bindir:$PATH" HOME="/tmp/nonexistent_xyz" bash "$launcher_name" $extra_args 2>/dev/null) || true
    [ -f "$capture" ] && cat "$capture" || true
}

captured21_claude_shape=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "claude-shape.sh" "claude" "t21-pitch")
assert_contains "(21) claude-shape: required_platforms reaches args" "required_platforms: [darwin, linux]" "$captured21_claude_shape"
assert_contains "(21) claude-shape: Always Load file still forwarded" "REPO_STRUCTURE_CONTENT" "$captured21_claude_shape"
assert_contains "(21) claude-shape: matched Domain-table file still forwarded" "HARNESSES_CONTENT" "$captured21_claude_shape"
assert_not_contains "(21) claude-shape: unmatched Domain-table file not forwarded" "HOOKS_CONTENT" "$captured21_claude_shape"

captured21_pi_shape=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/pi/pi-shape.sh" "pi-shape.sh" "pi" "t21-pitch")
assert_contains "(21) pi-shape: required_platforms reaches args" "required_platforms: [darwin, linux]" "$captured21_pi_shape"
assert_contains "(21) pi-shape: Always Load file still forwarded" "REPO_STRUCTURE_CONTENT" "$captured21_pi_shape"
assert_contains "(21) pi-shape: matched Domain-table file still forwarded" "HARNESSES_CONTENT" "$captured21_pi_shape"
assert_not_contains "(21) pi-shape: unmatched Domain-table file not forwarded" "HOOKS_CONTENT" "$captured21_pi_shape"

captured21_claude_experiment=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/claude/claude-experiment.sh" "claude-experiment.sh" "claude" "")
assert_contains "(21) claude-experiment: required_platforms reaches args (Tier-0)" "required_platforms: [darwin, linux]" "$captured21_claude_experiment"
assert_contains "(21) claude-experiment: Always Load file still forwarded" "REPO_STRUCTURE_CONTENT" "$captured21_claude_experiment"

captured21_pi_experiment=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/pi/pi-experiment.sh" "pi-experiment.sh" "pi" "")
assert_contains "(21) pi-experiment: required_platforms reaches args (Tier-0)" "required_platforms: [darwin, linux]" "$captured21_pi_experiment"
assert_contains "(21) pi-experiment: Always Load file still forwarded" "REPO_STRUCTURE_CONTENT" "$captured21_pi_experiment"

# ── Test 22: citation priority — explicit context/<name>.md citation wins ─────
T22="$BASE_TMP/t22_citation_priority"
mkdir -p "$T22/context" "$T22/codegen/pitches/draft"
cat >"$T22/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/kw-a.md` | A | dispatch.sh | a/ |
| `context/kw-b.md` | B | dispatch.sh | b/ |
| `context/kw-c.md` | C | dispatch.sh | c/ |
| `context/cited-d.md` | D | dispatch.sh | d/ |
| `context/cited-e.md` | E | dispatch.sh | e/ |
| `context/cited-f.md` | F | dispatch.sh | f/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T22/context/repo-structure.md"
printf 'KWA_CONTENT' >"$T22/context/kw-a.md"
printf 'KWB_CONTENT' >"$T22/context/kw-b.md"
printf 'KWC_CONTENT' >"$T22/context/kw-c.md"
printf 'CITEDD_CONTENT' >"$T22/context/cited-d.md"
printf 'CITEDE_CONTENT' >"$T22/context/cited-e.md"
printf 'CITEDF_CONTENT' >"$T22/context/cited-f.md"
# All 6 rows keyword-match ("dispatch.sh"); rows d/e/f are ALSO explicitly
# cited by exact repo-relative path. Cap is 6, but citation priority must
# put d/e/f ahead of a/b/c, so at most 3 of a/b/c survive.
cat >"$T22/codegen/pitches/draft/t22-pitch.md" <<'EOF'
## Problem
Need to fix dispatch.sh routing. See context/cited-d.md, context/cited-e.md,
context/cited-f.md for full detail.
EOF

BIN22="$BASE_TMP/t22_bin"
mkdir -p "$BIN22"
CAPTURE22="$BASE_TMP/t22_args.txt"
make_stub "$BIN22/claude" "printf '%s\n' \"\$@\" > '$CAPTURE22'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN22/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T22/claude-shape.sh"
ln -sf "$CODEGEN_ROOT/harnesses" "$T22/harnesses"

actual_exit=0
(cd "$T22" && PATH="$BIN22:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh t22-pitch 2>/dev/null) || actual_exit=$?
captured22=""
[ -f "$CAPTURE22" ] && captured22=$(cat "$CAPTURE22")
assert_contains "(22) citation priority: cited-d.md content in args" "CITEDD_CONTENT" "$captured22"
assert_contains "(22) citation priority: cited-e.md content in args" "CITEDE_CONTENT" "$captured22"
assert_contains "(22) citation priority: cited-f.md content in args" "CITEDF_CONTENT" "$captured22"

# ── Test 23: cited-only beats keyword-only ─────────────────────────────────────
T23="$BASE_TMP/t23_cited_only"
mkdir -p "$T23/context" "$T23/codegen/pitches/draft"
cat >"$T23/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/kw-only.md` | A | dispatch.sh | a/ |
| `context/cited-only.md` | B | never-matches-token | b/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T23/context/repo-structure.md"
printf 'KWONLY_CONTENT' >"$T23/context/kw-only.md"
printf 'CITEDONLY_CONTENT' >"$T23/context/cited-only.md"
# kw-only.md matches by keyword ("dispatch.sh"); cited-only.md has no
# keyword match but IS explicitly cited by exact path. Both must load
# (cap 6 not reached), but cited-only.md is tier 2 and kw-only.md is tier 3.
printf '## Problem\nFix dispatch.sh. See context/cited-only.md.\n' >"$T23/codegen/pitches/draft/t23-pitch.md"

BIN23="$BASE_TMP/t23_bin"
mkdir -p "$BIN23"
CAPTURE23="$BASE_TMP/t23_args.txt"
make_stub "$BIN23/claude" "printf '%s\n' \"\$@\" > '$CAPTURE23'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN23/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T23/claude-shape.sh"
ln -sf "$CODEGEN_ROOT/harnesses" "$T23/harnesses"

actual_exit=0
(cd "$T23" && PATH="$BIN23:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh t23-pitch 2>/dev/null) || actual_exit=$?
captured23=""
[ -f "$CAPTURE23" ] && captured23=$(cat "$CAPTURE23")
assert_contains "(23) cited-only: cited-only.md content in args" "CITEDONLY_CONTENT" "$captured23"
assert_contains "(23) cited-only: kw-only.md content still in args (cap not reached)" "KWONLY_CONTENT" "$captured23"
# Order check: cited-only.md (tier 2) must appear BEFORE kw-only.md (tier 3)
_t23_cited_pos=$(printf '%s' "$captured23" | grep -n "CITEDONLY_CONTENT" | head -1 | cut -d: -f1)
_t23_kw_pos=$(printf '%s' "$captured23" | grep -n "KWONLY_CONTENT" | head -1 | cut -d: -f1)
if [[ -n "$_t23_cited_pos" && -n "$_t23_kw_pos" && "$_t23_cited_pos" -lt "$_t23_kw_pos" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (23) cited-only.md ordered before kw-only.md\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (23) cited-only.md not ordered before kw-only.md (cited=%s kw=%s)\n' "$_t23_cited_pos" "$_t23_kw_pos"
    fail=$((fail + 1))
fi

# ── Test 24: no-citation pitch — byte-identical to pre-change table order ─────
T24="$BASE_TMP/t24_no_citation"
mkdir -p "$T24/context" "$T24/codegen/pitches/draft"
cat >"$T24/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/harnesses.md` | Harness specifics | claude-shape, dispatch.sh, launcher | harnesses/ |
| `context/hooks.md` | Hook system | PreToolUse, SubagentStop, hook test | harnesses/*/hooks/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T24/context/repo-structure.md"
printf 'HARNESSES_CONTENT' >"$T24/context/harnesses.md"
printf 'HOOKS_CONTENT' >"$T24/context/hooks.md"
# Pitch contains zero "context/" path strings — pure keyword match, same as Test 18.
printf '## Problem\nNeed to fix dispatch.sh routing logic.\n' >"$T24/codegen/pitches/draft/t24-pitch.md"

BIN24="$BASE_TMP/t24_bin"
mkdir -p "$BIN24"
CAPTURE24="$BASE_TMP/t24_args.txt"
make_stub "$BIN24/claude" "printf '%s\n' \"\$@\" > '$CAPTURE24'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN24/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T24/claude-shape.sh"
ln -sf "$CODEGEN_ROOT/harnesses" "$T24/harnesses"

actual_exit=0
(cd "$T24" && PATH="$BIN24:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh t24-pitch 2>/dev/null) || actual_exit=$?
captured24=""
[ -f "$CAPTURE24" ] && captured24=$(cat "$CAPTURE24")
assert_contains "(24) no-citation: matched context file content in args" "HARNESSES_CONTENT" "$captured24"
assert_not_contains "(24) no-citation: unmatched context file not in args" "HOOKS_CONTENT" "$captured24"

# ── Test 25: cap warning names only lower-priority losing rows ────────────────
T25="$BASE_TMP/t25_cap_warning"
mkdir -p "$T25/context" "$T25/codegen/pitches/draft"
cat >"$T25/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/r1.md` | A | dispatch.sh | a/ |
| `context/r2.md` | B | dispatch.sh | b/ |
| `context/r3.md` | C | dispatch.sh | c/ |
| `context/r4.md` | D | dispatch.sh | d/ |
| `context/r5.md` | E | dispatch.sh | e/ |
| `context/r6.md` | F | dispatch.sh | f/ |
| `context/r7.md` | G | dispatch.sh | g/ |
| `context/r8.md` | H | dispatch.sh | h/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T25/context/repo-structure.md"
for _n in 1 2 3 4 5 6 7 8; do printf 'R%sCONTENT' "$_n" >"$T25/context/r${_n}.md"; done
printf '## Problem\nFix dispatch.sh.\n' >"$T25/codegen/pitches/draft/t25-pitch.md"

BIN25="$BASE_TMP/t25_bin"
mkdir -p "$BIN25"
CAPTURE25="$BASE_TMP/t25_args.txt"
STDERR25="$BASE_TMP/t25_stderr.txt"
make_stub "$BIN25/claude" "printf '%s\n' \"\$@\" > '$CAPTURE25'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN25/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T25/claude-shape.sh"
ln -sf "$CODEGEN_ROOT/harnesses" "$T25/harnesses"

actual_exit=0
(cd "$T25" && PATH="$BIN25:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh t25-pitch 2>"$STDERR25") || actual_exit=$?
captured25=""
[ -f "$CAPTURE25" ] && captured25=$(cat "$CAPTURE25")
stderr25=""
[ -f "$STDERR25" ] && stderr25=$(cat "$STDERR25")
assert_contains "(25) cap warning: r7.md skip warning present" "Tier-1 cap (6) reached; skipping context/r7.md" "$stderr25"
assert_contains "(25) cap warning: r8.md skip warning present" "Tier-1 cap (6) reached; skipping context/r8.md" "$stderr25"
assert_not_contains "(25) cap warning: r1.md (selected) not in skip warnings" "skipping context/r1.md" "$stderr25"
assert_contains "(25) cap warning: r1.md content selected" "R1CONTENT" "$captured25"

# ── Test 26: missing selected file fails loud ──────────────────────────────────
T26="$BASE_TMP/t26_missing_file"
mkdir -p "$T26/context" "$T26/codegen/pitches/draft"
cat >"$T26/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/missing-row.md` | A | dispatch.sh | a/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T26/context/repo-structure.md"
# context/missing-row.md is deliberately NOT created on disk.
printf '## Problem\nFix dispatch.sh.\n' >"$T26/codegen/pitches/draft/t26-pitch.md"

BIN26="$BASE_TMP/t26_bin"
mkdir -p "$BIN26"
CAPTURE26="$BASE_TMP/t26_args.txt"
STDERR26="$BASE_TMP/t26_stderr.txt"
make_stub "$BIN26/claude" "printf '%s\n' \"\$@\" > '$CAPTURE26'"
if command -v yq >/dev/null 2>&1; then
    ln -s "$(command -v yq)" "$BIN26/yq"
fi
cp "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "$T26/claude-shape.sh"
ln -sf "$CODEGEN_ROOT/harnesses" "$T26/harnesses"

actual_exit=0
(cd "$T26" && PATH="$BIN26:$PATH" HOME="/tmp/nonexistent_xyz" bash claude-shape.sh t26-pitch 2>"$STDERR26") || actual_exit=$?
stderr26=""
[ -f "$STDERR26" ] && stderr26=$(cat "$STDERR26")
assert_exit "(26) missing selected file: launcher exits non-zero" "1" "$actual_exit"
assert_contains "(26) missing selected file: stderr names the missing file" "is indexed but missing" "$stderr26"
if [ -f "$CAPTURE26" ]; then
    printf 'FAIL: (26) missing selected file: stub CLI was invoked despite required-context failure\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (26) missing selected file: stub CLI never invoked\n'
    pass=$((pass + 1))
fi

# ── Test 27: all four production callers route through the same selector ─────
T27="$BASE_TMP/t27_all_callers"
mkdir -p "$T27/context" "$T27/codegen/pitches/draft"
cat >"$T27/PROJECT_CONTEXT.md" <<'EOF'
## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/kw-only27.md` | A | dispatch.sh | a/ |
| `context/cited-only27.md` | B | never-matches-token | b/ |

## Always Load

- repo-structure.md

## Next
EOF
printf 'REPO_STRUCTURE_CONTENT' >"$T27/context/repo-structure.md"
printf 'KWONLY27_CONTENT' >"$T27/context/kw-only27.md"
printf 'CITEDONLY27_CONTENT' >"$T27/context/cited-only27.md"
printf '## Problem\nFix dispatch.sh. See context/cited-only27.md.\n' >"$T27/codegen/pitches/draft/t27-pitch.md"

captured27_claude_shape=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/claude/claude-shape.sh" "claude-shape.sh" "claude" "t27-pitch" "$T27")
assert_contains "(27) claude-shape: cited file reaches args" "CITEDONLY27_CONTENT" "$captured27_claude_shape"

captured27_pi_shape=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/pi/pi-shape.sh" "pi-shape.sh" "pi" "t27-pitch" "$T27")
assert_contains "(27) pi-shape: cited file reaches args" "CITEDONLY27_CONTENT" "$captured27_pi_shape"

captured27_claude_experiment=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/claude/claude-experiment.sh" "claude-experiment.sh" "claude" "t27-pitch" "$T27")
assert_contains "(27) claude-experiment: cited file reaches args" "CITEDONLY27_CONTENT" "$captured27_claude_experiment"

captured27_pi_experiment=$(run_t21_launcher "$CODEGEN_ROOT/harnesses/pi/pi-experiment.sh" "pi-experiment.sh" "pi" "t27-pitch" "$T27")
assert_contains "(27) pi-experiment: cited file reaches args" "CITEDONLY27_CONTENT" "$captured27_pi_experiment"

# (28) run_t21_launcher creates a <target>/harnesses symlink on EVERY call, and
# the same target dir serves several launchers above. Assert repeated `ln -sfn`
# calls never nest a harnesses/harnesses symlink inside the target — regression
# for the tracked artifact that leaked into the repo when this was `ln -sf`.
# Covers both the default T21 target and the explicit ones used by tests 22-27.
for _t28_dir in "$T21" "$T22" "$T27"; do
    [ -d "$_t28_dir" ] || continue
    if [ -e "$_t28_dir/harnesses/harnesses" ]; then
        printf 'FAIL: %s\n' "(28) repeated run_t21_launcher calls must not nest harnesses/harnesses in $_t28_dir"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "(28) no nested harnesses/harnesses in $_t28_dir"
        pass=$((pass + 1))
    fi
done

# ── Results ───────────────────────────────────────────────────────────────────
printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
