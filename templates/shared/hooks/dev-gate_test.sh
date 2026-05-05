#!/usr/bin/env bash
# dev-gate_test.sh — unit tests for dev-gate.sh
#
# Covers: short-gate-success (no block), short-gate-failure (block),
# long-gate-flag-file-shape, planner-gate-wins, no-step-log graceful exit,
# stop_hook_active short-circuit, non-developer agent_type no-op.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/dev-gate.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

assert_file_contains() {
    local desc="$1"
    local needle="$2"
    local file="$3"
    if [ -f "$file" ] && grep -qF "$needle" "$file"; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  file: %s\n' "$desc" "$needle" "$file"
        if [ -f "$file" ]; then printf '  contents:\n%s\n' "$(cat "$file")"; fi
        fail=$((fail + 1))
    fi
}

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
    )
    mkdir -p "$dir/.claude" "$dir/codegen/logging"
    printf '%s' "$dir"
}

input_for() {
    local cwd="$1"
    local agent_type="${2:-phoenix-developer}"
    local stop_active="${3:-false}"
    local sid="${4:-sess1}"
    cat <<JSON
{"hook_event_name":"SubagentStop","agent_type":"$agent_type","agent_id":"abc","session_id":"$sid","cwd":"$cwd","stop_hook_active":$stop_active}
JSON
}

# ── Test 1: stop_hook_active=true is a no-op ────────────────────────────────
T1=$(make_project)
out=$(printf '%s' "$(input_for "$T1" phoenix-developer true)" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "stop_hook_active short-circuits (no block)" '"decision":"block"' "$out"
rm -rf "$T1"

# ── Test 2: non-developer agent_type is a no-op ─────────────────────────────
T2=$(make_project)
out=$(printf '%s' "$(input_for "$T2" code-reviewer)" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-developer agent_type is no-op" '"decision":"block"' "$out"
rm -rf "$T2"

# ── Test 3: short-gate success (planner says `make true`) ───────────────────
T3=$(make_project)
LOG="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG" <<'MD'
# Step

## Plan

**Gate**: `true`

stuff
MD
# touch the log to ensure mtime within 60min (it already is)
out=$(printf '%s' "$(input_for "$T3")" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "short-gate success no block" '"decision":"block"' "$out"
assert_file_contains "short-gate success appends ALL CLEAR" "ALL CLEAR" "$LOG"
rm -rf "$T3"

# ── Test 4: short-gate failure emits block envelope ─────────────────────────
T4=$(make_project)
LOG="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_fail.md"
cat >"$LOG" <<'MD'
# Step

## Plan

**Gate**: `false`
MD
out=$(printf '%s' "$(input_for "$T4")" | bash "$HOOK" 2>/dev/null || true)
assert_contains "short-gate failure emits block" '"decision": "block"' "$out"
assert_file_contains "short-gate failure appends FAILED" "FAILED" "$LOG"
rm -rf "$T4"

# ── Test 5: long-gate flag file shape ───────────────────────────────────────
T5=$(make_project)
LOG="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_long.md"
cat >"$LOG" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
# Pre-empt: stub out `make` would actually run "make llm" forever. Instead,
# rely on the gate string going via `nohup bash -c "make llm > ..."` which
# fails fast in this temp dir (no Makefile). Either way the flag file is
# written before the gate completes. We just need to assert the flag exists
# and has the right keys.
out=$(printf '%s' "$(input_for "$T5" phoenix-developer false sess-long)" | bash "$HOOK" 2>/dev/null || true)
sleep 0.5
flag="$T5/codegen/gate-pending/sess-long.flag"
assert_file_contains "long-gate flag has gate=" "gate=make llm" "$flag"
assert_file_contains "long-gate flag has pid=" "pid=" "$flag"
assert_file_contains "long-gate flag has log=" "log=" "$flag"
assert_file_contains "long-gate flag has exitcode_file=" "exitcode_file=" "$flag"
assert_file_contains "long-gate flag has mode=long" "mode=long" "$flag"
assert_file_contains "long-gate flag has session_id" "session_id=sess-long" "$flag"
# latest.flag should point to (or copy) the same content
[ -e "$T5/codegen/gate-pending/latest.flag" ] && {
    printf 'PASS: latest.flag exists\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: latest.flag does not exist\n'
    fail=$((fail + 1))
}
assert_file_contains "long-gate placeholder VE section appended" "Long gate started" "$LOG"
# Cleanup any background process we may have spawned
pkill -f "make llm" 2>/dev/null || true
rm -rf "$T5"

# ── Test 6: planner gate wins over decision tree ────────────────────────────
T6=$(make_project)
# Add LLM-changing path that would normally produce `make ci && make llm`
# but planner says `true`. Project config defines the tree.
cat >"$T6/.claude/gate-config.sh" <<'EOF'
GATE_SHORT_DEFAULT="false"
GATE_SHORT_FINAL="false"
GATE_LLM="false"
GATE_LLM_AND_PHOENIX="false"
GATE_PHOENIX="false"
GATE_PHOENIX_VALIDATE_THEN="false"
GATE_PHOENIX_REBUILD_THEN="false"
LLM_PATHS_REGEX="CLAUDE\\.md"
PHOENIX_PATHS_REGEX="phoenix"
SEED_BUNDLE_PATH=""
SEED_SQL_PATH=""
SEED_VALIDATED_PATH=""
GATE_FINAL_STEP_DETECTOR="true"
EOF
echo "x" >"$T6/CLAUDE.md"
LOG="$T6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_planner.md"
cat >"$LOG" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
out=$(printf '%s' "$(input_for "$T6")" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner gate wins (no block from $(false))" '"decision":"block"' "$out"
assert_file_contains "planner gate logs $(true)" "Gate: true" "$LOG"
rm -rf "$T6"

# ── Test 7: no step log → graceful no-op (no flag file) ─────────────────────
T7=$(make_project)
# No log file in logging dir, no config — falls back to `make test` which
# would `block`. We assert it does not crash and emits one of the two valid
# outcomes (block or empty). The key assertion is no flag file is written
# for short gates.
out=$(printf '%s' "$(input_for "$T7")" | bash "$HOOK" 2>/dev/null || true)
[ ! -d "$T7/codegen/gate-pending" ] || [ -z "$(ls "$T7/codegen/gate-pending" 2>/dev/null)" ] && {
    printf 'PASS: no flag file written for short fallback gate\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: flag file written for short gate\n'
    fail=$((fail + 1))
}
rm -rf "$T7"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
