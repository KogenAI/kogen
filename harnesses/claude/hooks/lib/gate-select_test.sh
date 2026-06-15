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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
assert_eq "gate_timeout_for(make ci) = 900 (short)" "900" "$(gate_timeout_for 'make ci')"
assert_eq "gate_timeout_for(make llm-phoenix-validate) = 0 (short)" "0" "$(gate_timeout_for 'make llm-phoenix-validate')"
assert_eq "gate_timeout_for(make llm-phoenix) = 1500 (llm)" "1500" "$(gate_timeout_for 'make llm-phoenix')"
assert_eq "gate_timeout_for(rebuild-seed-then) = 1500" "1500" "$(gate_timeout_for 'CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix')"

# ── gate_mode_for ───────────────────────────────────────────────────────────
assert_eq "gate_mode_for(make ci) = short" "short" "$(gate_mode_for 'make ci')"
assert_eq "gate_mode_for(make ci) = short" "short" "$(gate_mode_for 'make ci')"
assert_eq "gate_mode_for(make llm) = long" "long" "$(gate_mode_for 'make llm')"
assert_eq "gate_mode_for(make llm-phoenix) = long" "long" "$(gate_mode_for 'make llm-phoenix')"
assert_eq "gate_mode_for(make ci && make llm) = long" "long" "$(gate_mode_for 'make ci && make llm')"
assert_eq "gate_mode_for(make llm-phoenix-validate) = short" "short" "$(gate_mode_for 'make llm-phoenix-validate')"
assert_eq "gate_mode_for(rebuild-seed-then) = long" "long" "$(gate_mode_for 'CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix')"

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

# ── No-config fallback (non-Phoenix) ────────────────────────────────────────
T_NOCFG=$(mktemp -d)
out=$(gate_select_decide "$T_NOCFG")
assert_eq "no-config fallback gate" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "no-config fallback mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "no-config fallback timeout" "timeout=0" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$T_NOCFG"

# ── No-config fallback (Phoenix — mix.exs present) ──────────────────────────
T_NOCFG_PHX=$(mktemp -d)
touch "$T_NOCFG_PHX/mix.exs"
out=$(gate_select_decide "$T_NOCFG_PHX")
assert_eq "no-config phoenix fallback gate" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "no-config phoenix fallback mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "no-config phoenix fallback timeout" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$T_NOCFG_PHX"

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

write_gate_config() {
    local dir="$1"
    cat >"$dir/.claude/gate-config.sh" <<EOF
GATE_SHORT_DEFAULT="make ci"
GATE_SHORT_FINAL="make ci"
GATE_LLM="make ci && make llm"
GATE_LLM_AND_PHOENIX="make ci && make llm && make llm-phoenix"
GATE_PHOENIX="make llm-phoenix"
GATE_PHOENIX_VALIDATE_THEN="make llm-phoenix-validate && make llm-phoenix"
GATE_PHOENIX_REBUILD_THEN="CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix"
LLM_PATHS_REGEX="(claude_runner_impl|claude_build_runner_impl|bouncer\\.ex|system_prompts|CLAUDE\\.md|codegen/rules/|codegen/recipes/|\\.md\\.j2\$|PLATFORM_INFO\\.md|llm_integration.*\\.exs)"
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
write_gate_config "$T1" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
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
write_gate_config "$T2" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T2/context/apps"
echo "x" >"$T2/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T2")
assert_eq "phoenix-only healthy seed gate" "gate=make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T2" "$SEED_DIR"

# ── Branch: PHOENIX, validated marker missing ──────────────────────────────
T3=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql"
write_gate_config "$T3" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T3/context/apps"
echo "x" >"$T3/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T3")
assert_eq "phoenix unvalidated gate" "gate=make llm-phoenix-validate && make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T3" "$SEED_DIR"

# ── Branch: PHOENIX, seed.bundle missing ───────────────────────────────────
T4=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_gate_config "$T4" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T4/context/apps"
echo "x" >"$T4/context/apps/CLAUDE-phoenix.md"
out=$(gate_select_decide "$T4")
assert_eq "phoenix rebuild-seed gate" "gate=CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T4" "$SEED_DIR"

# ── Branch: both LLM and PHOENIX changed ───────────────────────────────────
T5=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_gate_config "$T5" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
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
write_gate_config "$T6" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
mkdir -p "$T6/lib"
echo "x" >"$T6/lib/foo.ex"
out=$(gate_select_decide "$T6")
assert_eq "no-match final step gate" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T6" "$SEED_DIR"

# ── Planner gate wins over decision tree ───────────────────────────────────
T7=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
write_gate_config "$T7" "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
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

# ── GATE_FINAL_STEP_DETECTOR with exit-based script (regression: exit killed fn) ──
T9=$(make_project)
SEED_DIR=$(mktemp -d)
touch "$SEED_DIR/seed.bundle" "$SEED_DIR/seed.sql" "$SEED_DIR/validated"
# Use exit-based detector (like a real gate-config.sh) instead of "true"
cat >"$T9/.claude/gate-config.sh" <<'EOF'
GATE_SHORT_DEFAULT="make ci"
GATE_SHORT_FINAL="make ci"
GATE_LLM="make ci && make llm"
GATE_LLM_AND_PHOENIX="make ci && make llm && make llm-phoenix"
GATE_PHOENIX="make llm-phoenix"
GATE_PHOENIX_VALIDATE_THEN="make llm-phoenix-validate && make llm-phoenix"
GATE_PHOENIX_REBUILD_THEN="CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix"
LLM_PATHS_REGEX="(claude_runner_impl|CLAUDE\.md|codegen/rules/)"
PHOENIX_PATHS_REGEX="(context/apps/CLAUDE-phoenix\.md)"
GATE_FINAL_STEP_DETECTOR='exit 0'
EOF
mkdir -p "$T9/lib"
echo "x" >"$T9/lib/foo.ex"
out=$(gate_select_decide "$T9")
assert_eq "exit-detector final step gate" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "exit-detector final step mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
rm -rf "$T9" "$SEED_DIR"

# ── GATE_FINAL_STEP_DETECTOR with exit 1 → SHORT_DEFAULT ──────────────────
T10=$(make_project)
cat >"$T10/.claude/gate-config.sh" <<'EOF'
GATE_SHORT_DEFAULT="make ci"
GATE_SHORT_FINAL="make ci"
GATE_LLM="make ci && make llm"
GATE_LLM_AND_PHOENIX="make ci && make llm && make llm-phoenix"
GATE_PHOENIX="make llm-phoenix"
GATE_PHOENIX_VALIDATE_THEN="make llm-phoenix-validate && make llm-phoenix"
GATE_PHOENIX_REBUILD_THEN="CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix"
LLM_PATHS_REGEX="(claude_runner_impl|CLAUDE\.md|codegen/rules/)"
PHOENIX_PATHS_REGEX="(context/apps/CLAUDE-phoenix\.md)"
GATE_FINAL_STEP_DETECTOR='exit 1'
EOF
mkdir -p "$T10/lib"
echo "x" >"$T10/lib/foo.ex"
out=$(gate_select_decide "$T10")
assert_eq "exit-1-detector non-final gate" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$T10"

# ── JSON gate block tests ───────────────────────────────────────────────────

# Case J1: Valid gate-json block → correct command/mode/timeout extracted
TJ1=$(mktemp)
cat >"$TJ1" <<'MD'
# Step 1 — test

## Plan

**Gate**:

```gate-json
{
  "command": "make ci",
  "mode": "short",
  "timeout": 900
}
```

## Slices
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ1")
assert_eq "json gate: command" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "json gate: mode=short" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "json gate: timeout=900" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TJ1"

# Case J2: Valid gate-json block with long mode
TJ2=$(mktemp)
cat >"$TJ2" <<'MD'
# Step 1 — test

## Plan

**Gate**:

```gate-json
{
  "command": "make ci && make llm",
  "mode": "long",
  "timeout": 1800
}
```

## Slices
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ2")
assert_eq "json gate long: command" "gate=make ci && make llm" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "json gate long: mode=long" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "json gate long: timeout=1800" "timeout=1800" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TJ2"

# Case J3: Malformed JSON block → __GATE_PARSE_ERROR__
TJ3=$(mktemp)
cat >"$TJ3" <<'MD'
# Step 1 — test

## Plan

**Gate**:

```gate-json
{ "command": "make ci", bad json here
```

## Slices
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ3")
# gate_select_decide propagates the parse error sentinel
if printf '%s' "$out" | grep -q '__GATE_PARSE_ERROR__'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: malformed json block → __GATE_PARSE_ERROR__\n'
    pass=$((pass + 1))
else
    printf 'FAIL: malformed json block → expected __GATE_PARSE_ERROR__\n  out: %s\n' "$out"
    fail=$((fail + 1))
fi
rm -f "$TJ3"

# Case J4: No JSON block → prose fallback still works
TJ4=$(mktemp)
cat >"$TJ4" <<'MD'
# Step 1 — test

## Plan

**Gate**: `make test`

## Slices
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ4")
assert_eq "no json block prose fallback: command" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "no json block prose fallback: mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
rm -f "$TJ4"

# Case J5: JSON mode/timeout override classifier (command says make test but json says long/1500)
TJ5=$(mktemp)
cat >"$TJ5" <<'MD'
# Step 1 — test

## Plan

**Gate**:

```gate-json
{
  "command": "make test",
  "mode": "long",
  "timeout": 1500
}
```
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ5")
assert_eq "json mode override: mode=long (classifier would say short)" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "json timeout override: timeout=1500 (classifier would say 0)" "timeout=1500" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TJ5"

# Case J6: JSON block missing required field → parse error
TJ6=$(mktemp)
cat >"$TJ6" <<'MD'
# Step 1 — test

## Plan

**Gate**:

```gate-json
{
  "mode": "short",
  "timeout": 900
}
```
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ6")
if printf '%s' "$out" | grep -q '__GATE_PARSE_ERROR__'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: json missing command field → __GATE_PARSE_ERROR__\n'
    pass=$((pass + 1))
else
    printf 'FAIL: json missing command field → expected __GATE_PARSE_ERROR__\n  out: %s\n' "$out"
    fail=$((fail + 1))
fi
rm -f "$TJ6"

# Case J7: gate-json block in plan body as an EXAMPLE (not after **Gate**:) → prose fallback used
TJ7=$(mktemp)
cat >"$TJ7" <<'MD'
# Step — test

## Plan

**Goal**: Illustrate new gate format.

**Gate format (new)**: gate-json block after **Gate**: in ## Plan, jq-parsed.

**Key assumptions**:
- Example only: the block below is INSIDE a code fence demo, not the authoritative gate.

**Gate**: `make test`

## Files Modified

nothing
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ7")
assert_eq "example block in body not extracted: prose gate wins" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
rm -f "$TJ7"

# Case J8: gate-json block after **Gate**: in ## Plan → authoritative (not example)
TJ8=$(mktemp)
cat >"$TJ8" <<'MD'
# Step — test

## Plan

**Goal**: Real gate-json block.

**Gate**:

```gate-json
{
  "command": "make test",
  "mode": "short",
  "timeout": 0
}
```

## Files Modified

nothing
MD
out=$(gate_select_decide "$(mktemp -d)" "$TJ8")
assert_eq "authoritative gate-json block extracted" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
rm -f "$TJ8"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
