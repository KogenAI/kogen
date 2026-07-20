#!/usr/bin/env bash
# mode-thinking-parity_test.sh — every Claude launcher-backed mode declares
# one positive thinking_tokens ceiling in config.yaml, applied identically on
# interactive and headless branches via ROLE_THINKING_TOKENS (never a
# hard-coded positive literal), validated fail-loud by load_role() on
# malformed/zero config. Modes are derived from the manifest, not hardcoded,
# so a newly added Claude mode is picked up automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG="$CODEGEN_DIR/templates/generator/config.yaml"
MANIFEST="$CODEGEN_DIR/harnesses/claude/manifest.yaml"
LOAD_ROLE="$CODEGEN_DIR/harnesses/claude/load-role.sh"

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

if ! command -v yq >/dev/null 2>&1; then
    printf 'FAIL: yq not found\n'
    printf '\nResults: 0 passed, 1 failed\n'
    exit 1
fi

# Modes are derived from the manifest's `modes:` map keys, not hardcoded.
mapfile -t MODES < <(yq -r '.modes | keys | .[]' "$MANIFEST")
if [ "${#MODES[@]}" -eq 0 ]; then
    printf 'FAIL: no modes found in %s\n' "$MANIFEST"
    printf '\nResults: 0 passed, 1 failed\n'
    exit 1
fi

declare -A LAUNCHER_FOR=(
    [debug]="$CODEGEN_DIR/harnesses/claude/claude-debug.sh"
    [shape]="$CODEGEN_DIR/harnesses/claude/claude-shape.sh"
    [experiment]="$CODEGEN_DIR/harnesses/claude/claude-experiment.sh"
    [ops]="$CODEGEN_DIR/harnesses/claude/claude-ops.sh"
    [babysit]="$CODEGEN_DIR/harnesses/claude/claude-babysit.sh"
)

for mode in "${MODES[@]}"; do
    launcher="${LAUNCHER_FOR[$mode]:-}"
    if [ -z "$launcher" ]; then
        printf 'FAIL: no launcher mapped for manifest mode %q (add to LAUNCHER_FOR)\n' "$mode"
        fail=$((fail + 1))
        continue
    fi
    if [ ! -f "$launcher" ]; then
        printf 'FAIL: launcher not found at %s (mode %q)\n' "$launcher" "$mode"
        fail=$((fail + 1))
        continue
    fi

    # (1) config.yaml declares a positive-integer thinking_tokens for this role.
    declared=$(yq -r ".roles.$mode.thinking_tokens // \"\"" "$CONFIG")
    if [[ "$declared" =~ ^[0-9]+$ ]] && [ "$declared" -gt 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (%s) config.yaml declares positive thinking_tokens=%s\n' "$mode" "$declared"
        pass=$((pass + 1))
    else
        printf 'FAIL: (%s) config.yaml roles.%s.thinking_tokens missing/invalid: %q\n' "$mode" "$mode" "$declared"
        fail=$((fail + 1))
    fi

    # (2) launcher never hard-codes a positive numeric MAX_THINKING_TOKENS
    # literal — it must reference $ROLE_THINKING_TOKENS instead.
    if grep -Eq 'MAX_THINKING_TOKENS\\?":\\?"[0-9]+' "$launcher"; then
        printf 'FAIL: (%s) launcher %s hard-codes a positive MAX_THINKING_TOKENS literal\n' "$mode" "$(basename "$launcher")"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (%s) launcher has no hard-coded MAX_THINKING_TOKENS literal\n' "$mode"
        pass=$((pass + 1))
    fi

    # (3) launcher consumes ROLE_THINKING_TOKENS.
    role_ref_cnt=$(grep -c 'ROLE_THINKING_TOKENS' "$launcher" || true)
    if [ "$role_ref_cnt" -ge 1 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (%s) launcher references ROLE_THINKING_TOKENS\n' "$mode"
        pass=$((pass + 1))
    else
        printf 'FAIL: (%s) launcher %s never references ROLE_THINKING_TOKENS\n' "$mode" "$(basename "$launcher")"
        fail=$((fail + 1))
    fi

    # (4) every `--settings`/exec-claude site references $SETTINGS_JSON (var),
    # never a literal inline blob — so the resolved value always threads through.
    settings_total=$(grep -c -- '--settings' "$launcher" || true)
    settings_var=$(grep -c -- '--settings "\$SETTINGS_JSON"' "$launcher" || true)
    check "(${mode}) every --settings site references \$SETTINGS_JSON" "$settings_total" "$settings_var"

    # (5) both interactive and headless branches assign SETTINGS_JSON with
    # MAX_THINKING_TOKENS — i.e. the ceiling applies to both, not just one.
    both_branches=$(grep -c 'SETTINGS_JSON=.*MAX_THINKING_TOKENS' "$launcher" || true)
    if [ "$both_branches" -ge 2 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: (%s) MAX_THINKING_TOKENS present on both branches (%s assignments)\n' "$mode" "$both_branches"
        pass=$((pass + 1))
    else
        printf 'FAIL: (%s) expected >=2 SETTINGS_JSON assignments carrying MAX_THINKING_TOKENS, got %s\n' "$mode" "$both_branches"
        fail=$((fail + 1))
    fi
done

# AFK timeout stays interactive-only: on every mode, fewer SETTINGS_JSON
# assignments carry CLAUDE_AFK_TIMEOUT_MS than carry MAX_THINKING_TOKENS
# (shape has 2 exec sites — cold-start + normal — so its interactive-only
# count is 2, not 1; the other four modes have a single exec site each).
declare -A EXPECT_AFK=(
    [debug]=1
    [shape]=2
    [experiment]=1
    [ops]=1
    [babysit]=1
)
for mode in debug shape experiment ops babysit; do
    launcher="${LAUNCHER_FOR[$mode]}"
    afk_cnt=$(grep -c 'CLAUDE_AFK_TIMEOUT_MS' "$launcher" || true)
    check "(${mode}) CLAUDE_AFK_TIMEOUT_MS interactive-only occurrence count" "${EXPECT_AFK[$mode]}" "$afk_cnt"
done

# experiment keeps API_FORCE_IDLE_TIMEOUT on BOTH branches (regression guard).
EXPERIMENT_LAUNCHER="${LAUNCHER_FOR[experiment]}"
idle_cnt=$(grep -c 'API_FORCE_IDLE_TIMEOUT' "$EXPERIMENT_LAUNCHER" || true)
check "(experiment) API_FORCE_IDLE_TIMEOUT present on both branches" "2" "$idle_cnt"

# ── load_role() fail-loud validation on scratch configs ──────────────────────
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

make_fixture_ocg() {
    local dir="$1"
    local thinking_line="$2"
    mkdir -p "$dir/templates/generator" "$dir/harnesses/claude" "$dir/harnesses/shared"
    cp "$LOAD_ROLE" "$dir/harnesses/claude/load-role.sh"
    cp "$CODEGEN_DIR/harnesses/shared/mode-context.sh" "$dir/harnesses/shared/mode-context.sh"
    cat >"$dir/templates/generator/config.yaml" <<YAML
roles:
  scratch:
    model: opus
    effort: high
    system_prompt: "stub"
$thinking_line
YAML
}

run_load_role_scratch() {
    local dir="$1"
    (
        CODEGEN_DIR="$dir"
        export CODEGEN_DIR
        # shellcheck source=/dev/null
        source "$dir/harnesses/claude/load-role.sh"
        load_role scratch
        printf '%s' "$ROLE_THINKING_TOKENS"
    )
}

# (a) non-integer thinking_tokens → exit 1, error names role+key
NONINT_DIR="$FIXTURE_ROOT/nonint"
make_fixture_ocg "$NONINT_DIR" "    thinking_tokens: \"abc\""
nonint_err=""
nonint_rc=0
nonint_err=$(run_load_role_scratch "$NONINT_DIR" 2>&1 >/dev/null) || nonint_rc=$?
check "(a) non-integer thinking_tokens: exit code" "1" "$nonint_rc"
if [[ "$nonint_err" == *"thinking_tokens missing/invalid"* ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (a) error names thinking_tokens missing/invalid\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (a) error does not name thinking_tokens missing/invalid: %s\n' "$nonint_err"
    fail=$((fail + 1))
fi

# (b) zero thinking_tokens → exit 1
ZERO_DIR="$FIXTURE_ROOT/zero"
make_fixture_ocg "$ZERO_DIR" "    thinking_tokens: 0"
zero_rc=0
run_load_role_scratch "$ZERO_DIR" >/dev/null 2>&1 || zero_rc=$?
check "(b) zero thinking_tokens: exit code" "1" "$zero_rc"

# (c) valid positive integer → exports value, exit 0
VALID_DIR="$FIXTURE_ROOT/valid"
make_fixture_ocg "$VALID_DIR" "    thinking_tokens: 16000"
valid_rc=0
valid_out=""
valid_out=$(run_load_role_scratch "$VALID_DIR" 2>/dev/null) || valid_rc=$?
check "(c) valid thinking_tokens: exit code" "0" "$valid_rc"
check "(c) valid thinking_tokens: ROLE_THINKING_TOKENS exported" "16000" "$valid_out"

# (d) absent thinking_tokens (role legitimately doesn't declare one) → no
# failure, ROLE_THINKING_TOKENS empty. Mirrors roles like usage-rules/
# housekeeper/inspector/app_build that don't use thinking budgets.
ABSENT_DIR="$FIXTURE_ROOT/absent"
make_fixture_ocg "$ABSENT_DIR" ""
absent_rc=0
absent_out="unset"
absent_out=$(run_load_role_scratch "$ABSENT_DIR" 2>/dev/null) || absent_rc=$?
check "(d) absent thinking_tokens: exit code" "0" "$absent_rc"
check "(d) absent thinking_tokens: ROLE_THINKING_TOKENS empty" "" "$absent_out"

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
