#!/usr/bin/env bash
# gate-select_test.sh — unit tests for gate-select.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/gate-select.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# ── gate_timeout_for ────────────────────────────────────────────────────────
assert_eq "gate_timeout_for(make ci) = 900" "900" "$(gate_timeout_for 'make ci')"
assert_eq "gate_timeout_for(make llm) = 1500" "1500" "$(gate_timeout_for 'make llm')"
assert_eq "gate_timeout_for(make ci && make llm) = 1800" "1800" "$(gate_timeout_for 'make ci && make llm')"
assert_eq "gate_timeout_for(make ci-fast) = 0 (short)" "0" "$(gate_timeout_for 'make ci-fast')"
assert_eq "gate_timeout_for(make llm-phoenix-validate) = 0 (short)" "0" "$(gate_timeout_for 'make llm-phoenix-validate')"
assert_eq "gate_timeout_for(make llm-phoenix) = 1500 (llm)" "1500" "$(gate_timeout_for 'make llm-phoenix')"
assert_eq "gate_timeout_for(rebuild-seed-then) = 1500" "1500" "$(gate_timeout_for 'COMBOBULATE_VE_GATE=rebuild-seed-then make llm-phoenix')"

# ── gate_mode_for ───────────────────────────────────────────────────────────
assert_eq "gate_mode_for(make ci) = short" "short" "$(gate_mode_for 'make ci')"
assert_eq "gate_mode_for(make ci-fast) = short" "short" "$(gate_mode_for 'make ci-fast')"
assert_eq "gate_mode_for(make llm) = long" "long" "$(gate_mode_for 'make llm')"
assert_eq "gate_mode_for(make llm-phoenix) = long" "long" "$(gate_mode_for 'make llm-phoenix')"
assert_eq "gate_mode_for(make ci && make llm) = long" "long" "$(gate_mode_for 'make ci && make llm')"
assert_eq "gate_mode_for(make llm-phoenix-validate) = short" "short" "$(gate_mode_for 'make llm-phoenix-validate')"
assert_eq "gate_mode_for(rebuild-seed-then) = long" "long" "$(gate_mode_for 'COMBOBULATE_VE_GATE=rebuild-seed-then make llm-phoenix')"

# ── gate_select_read_planner_gate ───────────────────────────────────────────

# Case 1: backticked gate value
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

**Gate**: `make ci`

stuff
MD
assert_eq "read_planner_gate: backticked" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 2: backticked + prose suffix
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

**Gate**: `make ci` (single-step task, full gate required)

stuff
MD
assert_eq "read_planner_gate: backticked + prose" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 3: bare value, no suffix
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci

stuff
MD
assert_eq "read_planner_gate: bare value" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 4: bare value + paren prose
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci (note)

stuff
MD
assert_eq "read_planner_gate: bare + paren prose" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 5: bare value + em dash (U+2014)
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci — note

stuff
MD
assert_eq "read_planner_gate: bare + em dash" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 6: plain Gate: prefix (no bold)
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

Gate: make ci

stuff
MD
assert_eq "read_planner_gate: plain Gate: prefix" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 7: ## Plan section with no Gate line
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

some content but no gate line

stuff
MD
assert_eq "read_planner_gate: no Gate line" "" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 8: Gate: line present but in ## Approach section (after ## Plan)
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

no gate here

## Approach

Gate: make ci
MD
assert_eq "read_planner_gate: Gate in wrong section" "" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 9: bare value + ASCII hyphen with surrounding spaces
TMP=$(mktemp)
cat >"$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci - note

stuff
MD
assert_eq "read_planner_gate: bare + hyphen separator" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# ── No-config fallback ──────────────────────────────────────────────────────
T_NOCFG=$(mktemp -d)
out=$(gate_select_decide "$T_NOCFG")
assert_eq "no-config fallback gate" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "no-config fallback mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "no-config fallback timeout" "timeout=0" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$T_NOCFG"

# ── Setup helpers ───────────────────────────────────────────────────────────
make_project() {
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir"
        git init -q
        git config user.email t@t
        git config user.name t
        git checkout -q -b main
        echo init >README
        git add README
        git commit -qm init
        git remote add origin "$dir/.git"
        git update-ref refs/remotes/origin/main HEAD
    )
    mkdir -p "$dir/.claude"
    printf '%s' "$dir"
}

write_combobulate_config() {
    local dir="$1"
    cat >"$dir/.claude/gate-config.sh" <<EOF
GATE_SHORT_DEFAULT="make ci-fast"
GATE_SHORT_FINAL="make ci"
GATE_LLM="make ci && make llm"
GATE_LLM_AND_PHOENIX="make ci && make llm && make llm-phoenix"
GATE_PHOENIX="make llm-phoenix"
GATE_PHOENIX_VALIDATE_THEN="make llm-phoenix-validate && make llm-phoenix"
GATE_PHOENIX_REBUILD_THEN="COMBOBULATE_VE_GATE=rebuild-seed-then make llm-phoenix"
LLM_PATHS_REGEX="(claude_runner_impl|(claude|codex)_build_runner_impl|bouncer\\.ex|system_prompts|CLAUDE\\.md|codegen/rules/|codegen/recipes/|\\.md\\.j2\$|PLATFORM_INFO\\.md|llm_integration.*\\.exs)"
PHOENIX_PATHS_REGEX="(context/apps/CLAUDE-phoenix\\.md|codegen/recipes/.*phoenix)"
SEED_BUNDLE_PATH="$2"
SEED_SQL_PATH="$3"
SEED_VALIDATED_PATH="$4"
GATE_FINAL_STEP_DETECTOR="true"
EOF
}

# ── Branch: only LLM paths changed ─────────────────────────────────────────
T1=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T1" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
echo "x" >"$T1/CLAUDE.md"
out=$(gate_select_decide "$T1")
assert_eq "llm-only branch gate" "gate=make ci && make llm" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "llm-only branch mode" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "llm-only branch timeout" "timeout=1800" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$T1" "$SEED_DIR"

# ── Branch: only PHOENIX paths changed, seed healthy ───────────────────────
T2=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T2" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T2/context/apps"
echo "x" >"$T2/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T2")
assert_eq "phoenix-only healthy seed gate" "gate=make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T2" "$SEED_DIR"

# ── Branch: PHOENIX, validated marker missing ──────────────────────────────
T3=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql"
write_combobulate_config "$T3" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T3/context/apps"
echo "x" >"$T3/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T3")
assert_eq "phoenix unvalidated gate" "gate=make llm-phoenix-validate && make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T3" "$SEED_DIR"

# ── Branch: PHOENIX, seed.bundle missing ───────────────────────────────────
T4=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T4" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T4/context/apps"
echo "x" >"$T4/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T4")
assert_eq "phoenix rebuild-seed gate" "gate=COMBOBULATE_VE_GATE=rebuild-seed-then make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T4" "$SEED_DIR"

# ── Branch: both LLM and PHOENIX changed ───────────────────────────────────
T5=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T5" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T5/context/apps"
echo "x" >"$T5/CLAUDE.md"
echo "y" >"$T5/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T5")
assert_eq "llm+phoenix gate" "gate=make ci && make llm && make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T5" "$SEED_DIR"

# ── Branch: nothing matches → final step → make ci ─────────────────────────
T6=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T6" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T6/lib"
echo "x" >"$T6/lib/foo.ex"
out=$(gate_select_decide "$T6")
assert_eq "no-match final step gate" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T6" "$SEED_DIR"

# ── Planner gate wins over decision tree ───────────────────────────────────
T7=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T7" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
echo "x" >"$T7/CLAUDE.md"
LOG="$T7/step.md"
cat >"$LOG" <<'MD'
# Step

## Plan

**Gate**: `make ci`

stuff
MD
out=$(gate_select_decide "$T7" "$LOG")
assert_eq "planner gate wins" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "planner gate mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "planner gate timeout" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$T7" "$SEED_DIR"

# ── Branch: codex_build_runner_impl edited → LLM gate ──────────────────────
T8=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_combobulate_config "$T8" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T8/lib/combobulate/builds"
echo "x" >"$T8/lib/combobulate/builds/codex_build_runner_impl.ex"
out=$(gate_select_decide "$T8")
assert_eq "codex_build_runner_impl branch gate" "gate=make ci && make llm" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "codex_build_runner_impl branch mode" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "codex_build_runner_impl branch timeout" "timeout=1800" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$T8" "$SEED_DIR"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
