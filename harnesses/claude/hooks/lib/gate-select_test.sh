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

# ── No-config fallback (non-Phoenix) → unresolved sentinel ─────────────────
# `.claude/gate-config.sh` is the ONLY resolver — there is no second tier
# above it, so a missing config is always unresolved and the sentinel must
# name the exact path the operator has to create.
T_NOCFG=$(mktemp -d)
out=$(gate_select_decide "$T_NOCFG")
assert_eq "no-config → unresolved" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
assert_eq "no-config sentinel names the missing config path" \
    "__GATE_UNRESOLVED__:no $T_NOCFG/.claude/gate-config.sh" "$out"
rm -rf "$T_NOCFG"

# ── No-config fallback (mix.exs present) → still unresolved (no mix.exs guess) ──
T_NOCFG_PHX=$(mktemp -d)
touch "$T_NOCFG_PHX/mix.exs"
out=$(gate_select_decide "$T_NOCFG_PHX")
assert_eq "mix.exs present, no config → still unresolved" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
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

write_gate_command_config() {
    local dir="$1"
    local cmd="$2"
    printf 'GATE_COMMAND="%s"\n' "$cmd" >"$dir/.claude/gate-config.sh"
}

# ── GATE_COMMAND resolution from per-app config ─────────────────────────────
TGC1=$(make_project)
write_gate_command_config "$TGC1" "make ci"
out=$(gate_select_decide "$TGC1")
assert_eq "GATE_COMMAND resolves gate" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "GATE_COMMAND resolves mode" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "GATE_COMMAND resolves timeout" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGC1"

# ── GATE_COMMAND empty → unresolved sentinel ─────────────────────────────────
TGC2=$(make_project)
write_gate_command_config "$TGC2" ""
out=$(gate_select_decide "$TGC2")
assert_eq "empty GATE_COMMAND → unresolved" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
rm -rf "$TGC2"

# ── GATE_MODE / GATE_TIMEOUT overrides ──────────────────────────────────────
# Both are OPTIONAL. Unset → the gate_mode_for/gate_timeout_for heuristics.
# Set → verbatim, never re-derived. Malformed → __GATE_UNRESOLVED__, never a
# silent fall-back to the heuristic.

# Unset → heuristics still apply. "make test" matches neither heuristic branch,
# so this is the derived-zero case the overrides exist to let a project fix.
TGO1=$(make_project)
write_gate_command_config "$TGO1" "make test"
out=$(gate_select_decide "$TGO1")
assert_eq "no overrides: mode from gate_mode_for" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "no overrides: timeout from gate_timeout_for" "timeout=0" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO1"

# GATE_TIMEOUT set → wins over the derived 0.
TGO2=$(make_project)
printf 'GATE_COMMAND="make test"\nGATE_TIMEOUT=900\n' >"$TGO2/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO2")
assert_eq "GATE_TIMEOUT override: gate unchanged" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "GATE_TIMEOUT override: mode still derived" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "GATE_TIMEOUT override: timeout=900 (heuristic would say 0)" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO2"

# GATE_MODE set → wins over the derived short.
TGO3=$(make_project)
printf 'GATE_COMMAND="make ci"\nGATE_MODE=long\n' >"$TGO3/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO3")
assert_eq "GATE_MODE override: mode=long (heuristic would say short)" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "GATE_MODE override: timeout still derived" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO3"

# Both set → both verbatim.
TGO4=$(make_project)
printf 'GATE_COMMAND="make ci"\nGATE_MODE=long\nGATE_TIMEOUT=120\n' >"$TGO4/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO4")
assert_eq "both overrides: mode" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "both overrides: timeout" "timeout=120" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO4"

# GATE_TIMEOUT=0 is a real declaration, not "unset" — it must be taken, not
# silently replaced by the heuristic's 900 for a `make ci` command.
TGO5=$(make_project)
printf 'GATE_COMMAND="make ci"\nGATE_TIMEOUT=0\n' >"$TGO5/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO5")
assert_eq "GATE_TIMEOUT=0 is honoured, not treated as unset" "timeout=0" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO5"

# Empty-string override is treated as unset (heuristic applies).
TGO6=$(make_project)
printf 'GATE_COMMAND="make ci"\nGATE_MODE=""\nGATE_TIMEOUT=""\n' >"$TGO6/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO6")
assert_eq "empty GATE_MODE falls back to heuristic" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "empty GATE_TIMEOUT falls back to heuristic" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO6"

# Malformed GATE_MODE → unresolved sentinel, never a silent heuristic fallback.
TGO7=$(make_project)
printf 'GATE_COMMAND="make ci"\nGATE_MODE=fast\n' >"$TGO7/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO7")
assert_eq "malformed GATE_MODE → unresolved" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
assert_eq "malformed GATE_MODE names the bad value" "1" "$(printf '%s' "$out" | grep -c 'GATE_MODE=fast')"
rm -rf "$TGO7"

# Malformed GATE_TIMEOUT → unresolved sentinel (LoopGate's String.to_integer
# would otherwise raise an opaque ArgumentError).
TGO8=$(make_project)
printf 'GATE_COMMAND="make ci"\nGATE_TIMEOUT=15m\n' >"$TGO8/.claude/gate-config.sh"
out=$(gate_select_decide "$TGO8")
assert_eq "malformed GATE_TIMEOUT → unresolved" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
assert_eq "malformed GATE_TIMEOUT names the bad value" "1" "$(printf '%s' "$out" | grep -c 'GATE_TIMEOUT=15m')"
rm -rf "$TGO8"

# A stale GATE_MODE/GATE_TIMEOUT in the CALLER's environment must not leak in —
# only what the config file itself declares counts (mirrors GATE_COMMAND's
# pre-clear).
TGO9=$(make_project)
write_gate_command_config "$TGO9" "make ci"
out=$(GATE_MODE=long GATE_TIMEOUT=1 gate_select_decide "$TGO9")
assert_eq "stale env GATE_MODE does not leak into the decision" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "stale env GATE_TIMEOUT does not leak into the decision" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -rf "$TGO9"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
