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

# write_plan_gate_event <path> <command> <mode> <timeout> [<role>] — writes a
# single {"ev":"plan_gate",...} JSONL line, matching what
# `codegen-log append <role> --plan-gate @-` actually writes on disk. This is
# the structured event gate_select_read_planner_gate / gate_select_decide
# read — the old markdown "**Gate**:"/```gate-json prose scanners were
# hard-deleted; a plan_gate event is the ONLY input they accept now.
write_plan_gate_event() {
    local path="$1"
    local command="$2"
    local mode="$3"
    local timeout="$4"
    local role="${5:-planner-phoenix}"
    jq -c -n --arg role "$role" --arg command "$command" --arg mode "$mode" --argjson timeout "$timeout" \
        '{ev: "plan_gate", role: $role, command: $command, mode: $mode, timeout: $timeout}' >"$path"
}

# write_role_body <path> <role> <body> — writes a plain {"ev":"role",...}
# event with free-form prose body. Used to prove the prose scanner is truly
# gone: a body containing "**Gate**:"/```gate-json markdown must NOT be
# picked up by the structured reader.
write_role_body() {
    local path="$1"
    local role="$2"
    local body="$3"
    jq -c -n --arg role "$role" --arg body "$body" \
        '{ev: "role", role: $role, body: $body}' >"$path"
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

# ── gate_select_read_planner_gate — structured event only ──────────────────

# Case 1: a plan_gate event resolves command/mode/timeout verbatim.
TMP=$(mktemp)
write_plan_gate_event "$TMP" "make ci" "short" "900"
out=$(gate_select_read_planner_gate "$TMP")
assert_eq "read_planner_gate: command" "make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "read_planner_gate: mode" "__GATE_JSON_MODE=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "read_planner_gate: timeout" "__GATE_JSON_TIMEOUT=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TMP"

# Case 2: no plan_gate event in the log (only a plain role body) → empty,
# even when that body contains old-style "**Gate**:" prose. Proves the
# prose scanner is truly gone — this body would have matched the old awk
# parser, and must NOT match the structured reader.
TMP=$(mktemp)
write_role_body "$TMP" "planner-phoenix" "## Plan

**Gate**: \`make evil\`

stuff"
assert_eq "no plan_gate event: prose **Gate**: line is never re-parsed" "" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 3: missing log file → empty
assert_eq "missing log file: empty" "" "$(gate_select_read_planner_gate "/nonexistent/path/does-not-exist.jsonl")"

# Case 4: plan_gate event authored by a non-planner role is ignored
TMP=$(mktemp)
write_plan_gate_event "$TMP" "make ci" "short" "900" "developer-phoenix-backend"
assert_eq "plan_gate authored by non-planner role is ignored" "" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 5: multiple plan_gate events (planner re-run) — the LAST one wins.
TMP=$(mktemp)
{
    jq -c -n '{ev: "plan_gate", role: "planner-phoenix", command: "make old", mode: "short", timeout: 900}'
    jq -c -n '{ev: "plan_gate", role: "planner-phoenix", command: "make new", mode: "long", timeout: 1500}'
} >"$TMP"
out=$(gate_select_read_planner_gate "$TMP")
assert_eq "multiple plan_gate events: last wins" "make new" "$(printf '%s' "$out" | sed -n '1p')"
rm -f "$TMP"

# ── gate_select_read_planner_plan — structured event only ──────────────────

# write_plan_event <path> <plan-text> [<role>] — writes a single
# {"ev":"plan",...} JSONL line, matching what
# `codegen-log append <role> --plan @-` actually writes on disk.
write_plan_event() {
    local path="$1"
    local plan="$2"
    local role="${3:-planner-phoenix}"
    jq -c -n --arg role "$role" --arg plan "$plan" \
        '{ev: "plan", role: $role, plan: $plan}' >"$path"
}

# Case 1: a plan event resolves the raw text verbatim.
TMP=$(mktemp)
write_plan_event "$TMP" "## Plan

Do the thing."
assert_eq "read_planner_plan: text" "## Plan

Do the thing." "$(gate_select_read_planner_plan "$TMP")"
rm -f "$TMP"

# Case 2: no plan event in the log (only a plain role body) → empty, even
# when that body itself contains "## Plan" markdown. Proves the plan is a
# typed event, never re-parsed out of role body prose.
TMP=$(mktemp)
write_role_body "$TMP" "planner-phoenix" "## Plan

Do the thing."
assert_eq "no plan event: prose ## Plan heading is never re-parsed" "" "$(gate_select_read_planner_plan "$TMP")"
rm -f "$TMP"

# Case 3: missing log file → empty
assert_eq "missing log file: empty" "" "$(gate_select_read_planner_plan "/nonexistent/path/does-not-exist.jsonl")"

# Case 4: plan event authored by a non-planner role is ignored
TMP=$(mktemp)
write_plan_event "$TMP" "some plan text" "developer-phoenix-backend"
assert_eq "plan authored by non-planner role is ignored" "" "$(gate_select_read_planner_plan "$TMP")"
rm -f "$TMP"

# Case 5: multiple plan events (planner re-run) — the LAST one wins.
TMP=$(mktemp)
{
    jq -c -n '{ev: "plan", role: "planner-phoenix", plan: "old plan"}'
    jq -c -n '{ev: "plan", role: "planner-phoenix", plan: "new plan"}'
} >"$TMP"
assert_eq "multiple plan events: last wins" "new plan" "$(gate_select_read_planner_plan "$TMP")"
rm -f "$TMP"

# ── No-config fallback (non-Phoenix) → unresolved sentinel ─────────────────
T_NOCFG=$(mktemp -d)
out=$(gate_select_decide "$T_NOCFG")
assert_eq "no-config → unresolved" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
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

# ── Planner gate wins over per-app GATE_COMMAND ─────────────────────────────
TGC3=$(make_project)
write_gate_command_config "$TGC3" "make ci"
LOG="$TGC3/step.jsonl"
write_plan_gate_event "$LOG" "make custom-gate" "short" "900"
out=$(gate_select_decide "$TGC3" "$LOG")
assert_eq "planner gate wins over GATE_COMMAND" "gate=make custom-gate" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$TGC3"

# ── plan_gate event tests (mode/timeout carried verbatim from the event) ───

# Case J1: plan_gate event → correct command/mode/timeout extracted
TJ1=$(mktemp)
write_plan_gate_event "$TJ1" "make ci" "short" "900"
out=$(gate_select_decide "$(mktemp -d)" "$TJ1")
assert_eq "plan_gate: command" "gate=make ci" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "plan_gate: mode=short" "mode=short" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "plan_gate: timeout=900" "timeout=900" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TJ1"

# Case J2: plan_gate event with long mode
TJ2=$(mktemp)
write_plan_gate_event "$TJ2" "make ci && make llm" "long" "1800"
out=$(gate_select_decide "$(mktemp -d)" "$TJ2")
assert_eq "plan_gate long: command" "gate=make ci && make llm" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "plan_gate long: mode=long" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "plan_gate long: timeout=1800" "timeout=1800" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TJ2"

# Case J5: event mode/timeout override the classifier (command says make
# test, which the classifier would call short/0, but the event says
# long/1500 — the event's own fields are authoritative, never re-derived).
TJ5=$(mktemp)
write_plan_gate_event "$TJ5" "make test" "long" "1500"
out=$(gate_select_decide "$(mktemp -d)" "$TJ5")
assert_eq "event mode override: mode=long (classifier would say short)" "mode=long" "$(printf '%s' "$out" | sed -n '2p')"
assert_eq "event timeout override: timeout=1500 (classifier would say 0)" "timeout=1500" "$(printf '%s' "$out" | sed -n '3p')"
rm -f "$TJ5"

# Case J7: a role body containing example gate-json/prose markdown (never a
# plan_gate event) → falls through to per-app GATE_COMMAND / unresolved.
# Proves example prose in a body is never mistaken for the authoritative
# selection now that the awk scanner is gone.
TJ7=$(mktemp)
write_role_body "$TJ7" "planner-phoenix" "## Plan

**Gate format (new)**: gate-json block after **Gate**: in ## Plan.

**Gate**: \`make test\`

## Files Modified

nothing"
out=$(gate_select_decide "$(mktemp -d)" "$TJ7")
assert_eq "prose-only body (no plan_gate event) never selects a gate" "1" "$(printf '%s' "$out" | grep -c '^__GATE_UNRESOLVED__:')"
rm -f "$TJ7"

# Case J8: a log carrying BOTH a prose role body (with stale-looking
# **Gate**: text) AND a real plan_gate event → the event wins, prose is
# ignored entirely.
TJ8=$(mktemp)
{
    jq -c -n --arg body '## Plan

**Gate**: `make stale-prose-gate`' '{ev: "role", role: "planner-phoenix", body: $body}'
    jq -c -n '{ev: "plan_gate", role: "planner-phoenix", command: "make test", mode: "short", timeout: 0}'
} >"$TJ8"
out=$(gate_select_decide "$(mktemp -d)" "$TJ8")
assert_eq "plan_gate event wins over stale prose in the same log" "gate=make test" "$(printf '%s' "$out" | sed -n '1p')"
rm -f "$TJ8"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
