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

# write_planner_log <path> <heredoc-body-via-stdin> — wraps the given
# markdown body (the "## Plan" prose planners write) into a single JSONL
# "role" event line, matching what codegen-log actually writes on disk. Test
# fixtures below pipe their markdown heredocs through this helper instead of
# writing raw markdown bytes directly, since gate_select_read_planner_gate /
# gate_select_decide now read the planner body via planner_body_from_log
# (jq-decoded from the JSONL cycle log), not raw file bytes.
write_planner_log() {
    local path="$1"
    local body
    body="$(cat)"
    jq -c -n --arg role "planner-phoenix" --arg body "$body" \
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

# ── gate_select_read_planner_gate ───────────────────────────────────────────

# Case 1: backticked gate value
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

**Gate**: `make ci`

stuff
MD
assert_eq "read_planner_gate: backticked" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 2: backticked + prose suffix
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

**Gate**: `make ci` (single-step task, full gate required)

stuff
MD
assert_eq "read_planner_gate: backticked + prose" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 3: bare value, no suffix
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci

stuff
MD
assert_eq "read_planner_gate: bare value" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 4: bare value + paren prose
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci (note)

stuff
MD
assert_eq "read_planner_gate: bare + paren prose" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 5: bare value + em dash (U+2014)
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci — note

stuff
MD
assert_eq "read_planner_gate: bare + em dash" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 6: plain Gate: prefix (no bold)
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

Gate: make ci

stuff
MD
assert_eq "read_planner_gate: plain Gate: prefix" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 7: ## Plan section with no Gate line
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

some content but no gate line

stuff
MD
assert_eq "read_planner_gate: no Gate line" "" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 8: Gate: line present later in the SAME planner body (no separate
# "## Approach" role-boundary exists any more — the whole body belongs to
# the planner's single "role" event under JSONL storage, so a Gate: line
# anywhere in that body is picked up).
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

no gate here

## Approach

Gate: make ci
MD
assert_eq "read_planner_gate: Gate line found anywhere in the planner's own body" "make ci" "$(gate_select_read_planner_gate "$TMP")"
rm -f "$TMP"

# Case 9: bare value + ASCII hyphen with surrounding spaces
TMP=$(mktemp)
write_planner_log "$TMP" <<'MD'
# Step

## Plan

**Gate**: make ci - note

stuff
MD
assert_eq "read_planner_gate: bare + hyphen separator" "make ci" "$(gate_select_read_planner_gate "$TMP")"
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
LOG="$TGC3/step.md"
write_planner_log "$LOG" <<'MD'
# Step

## Plan

**Gate**: `make custom-gate`

stuff
MD
out=$(gate_select_decide "$TGC3" "$LOG")
assert_eq "planner gate wins over GATE_COMMAND" "gate=make custom-gate" "$(printf '%s' "$out" | sed -n '1p')"
rm -rf "$TGC3"

# ── JSON gate block tests ───────────────────────────────────────────────────

# Case J1: Valid gate-json block → correct command/mode/timeout extracted
TJ1=$(mktemp)
write_planner_log "$TJ1" <<'MD'
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
write_planner_log "$TJ2" <<'MD'
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
write_planner_log "$TJ3" <<'MD'
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
write_planner_log "$TJ4" <<'MD'
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
write_planner_log "$TJ5" <<'MD'
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
write_planner_log "$TJ6" <<'MD'
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
write_planner_log "$TJ7" <<'MD'
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
write_planner_log "$TJ8" <<'MD'
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
