#!/usr/bin/env bash
# phoenix-dev-gate-short_test.sh — gate-validation tests (short gate, no long-running stub).
#
# Tests: 1-4, 6, 7, 15, 18, 19, 20, 21
# Covers: stop_hook_active short-circuit, non-developer no-op, short-gate success/failure,
# planner-gate-wins, no-step-log graceful exit, pre-seeded terminal flag sweep,
# A+B transcript-vs-mtime regression, attempt labeling, no-op gate detection.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/phoenix-dev-gate.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# assert_file_matches_jq <desc> <jq-select-expr> <file> — presence check via
# jq (at least one matching JSONL line). Mirrors the old assert_file_contains
# grep helper but at the event level rather than raw-text substring.
assert_file_matches_jq() {
    local desc="$1"
    local expr="$2"
    local file="$3"
    if [ -f "$file" ] && jq -e "$expr" "$file" >/dev/null 2>&1; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expr: %s\n  file: %s\n' "$desc" "$expr" "$file"
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

# write_planner_log <path> — wraps the markdown body piped on stdin (the
# "## Plan" prose planners write) into a single JSONL "role" event line,
# matching what codegen-log actually writes on disk.
write_planner_log() {
    local path="$1"
    local body
    body="$(cat)"
    jq -c -n --arg role "planner-phoenix" --arg body "$body" \
        '{ev: "role", role: $role, body: $body}' >"$path"
}

# make_transcript <transcript_path> <log_path> — write a synthetic JSONL
# transcript recording a Write to <log_path>.
make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

input_for() {
    local cwd="$1"
    local agent_type="${2:-developer-phoenix-backend}"
    local stop_active="${3:-false}"
    local sid="${4:-sess1}"
    local transcript_path="${5:-}"
    cat <<JSON
{"hook_event_name":"SubagentStop","agent_type":"$agent_type","agent_id":"abc","session_id":"$sid","cwd":"$cwd","stop_hook_active":$stop_active,"transcript_path":"$transcript_path"}
JSON
}

# ── Test 1: stop_hook_active=true is a no-op ────────────────────────────────
T1=$(make_project)
out=$(printf '%s' "$(input_for "$T1" developer-phoenix-backend true)" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "stop_hook_active short-circuits (no block)" '"decision":"block"' "$out"
rm -rf "$T1"

# ── Test 2: non-developer agent_type is a no-op ─────────────────────────────
T2=$(make_project)
out=$(printf '%s' "$(input_for "$T2" reviewer-phoenix)" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-developer agent_type is no-op" '"decision":"block"' "$out"
rm -rf "$T2"

# ── Test 3: short-gate success (planner says `make true`) ───────────────────
T3=$(make_project)
LOG="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
write_planner_log "$LOG" <<'MD'
# Step

## Plan

**Gate**: `true`

stuff
MD
make_transcript "$T3/transcript.jsonl" "$LOG"
out=$(printf '%s' "$(input_for "$T3" developer-phoenix-backend false sess1 "$T3/transcript.jsonl")" | RENDER_CHECK_CMD="" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "short-gate success no block" '"decision":"block"' "$out"
assert_file_matches_jq "short-gate success appends ALL CLEAR" 'select(.ev=="gate" and .verdict=="clear")' "$LOG"
rm -rf "$T3"

# ── Test 4: short-gate failure emits block envelope ─────────────────────────
T4=$(make_project)
LOG="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_fail_cycle.jsonl"
write_planner_log "$LOG" <<'MD'
# Step

## Plan

**Gate**: `false`
MD
make_transcript "$T4/transcript.jsonl" "$LOG"
out=$(printf '%s' "$(input_for "$T4" developer-phoenix-backend false sess1 "$T4/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
assert_contains "short-gate failure emits block" '"decision": "block"' "$out"
assert_file_matches_jq "short-gate failure appends FAILED" 'select(.ev=="gate" and .verdict=="failed")' "$LOG"
rm -rf "$T4"

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
LOG="$T6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_planner_cycle.jsonl"
write_planner_log "$LOG" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T6/transcript.jsonl" "$LOG"
out=$(printf '%s' "$(input_for "$T6" developer-phoenix-backend false sess1 "$T6/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner gate wins (no block from $(false))" '"decision":"block"' "$out"
assert_file_matches_jq "planner gate logs $(true)" 'select(.ev=="gate" and .gate=="true")' "$LOG"
rm -rf "$T6"

# ── Test 7: no step log → graceful no-op (no flag file) ─────────────────────
# No log file and no transcript → hook exits 0 immediately (no session log in transcript)
T7=$(make_project)
out=$(printf '%s' "$(input_for "$T7")" | bash "$HOOK" 2>/dev/null || true)
[ ! -d "$T7/codegen/gate-pending" ] || [ -z "$(ls "$T7/codegen/gate-pending" 2>/dev/null)" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: no flag file written for short fallback gate\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: flag file written for short gate\n'
    fail=$((fail + 1))
}
rm -rf "$T7"

# ── Test 15: short-gate sweeps pre-seeded terminal flag ─────────────────────
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_sweep_short_cycle.jsonl"
write_planner_log "$LOG15" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
mkdir -p "$T15/codegen/gate-pending"
# Seed a terminal exitcode file then a flag pointing at it.
ec15="$T15/codegen/gate-pending/oldsession-stale.log.exitcode"
echo 0 >"$ec15"
cat >"$T15/codegen/gate-pending/latest.flag" <<EOF
gate=make llm
pid=99999
log=$T15/codegen/gate-pending/oldsession-stale.log
exitcode_file=$ec15
started_at=2026-01-01T00:00:00Z
session_id=oldsession
mode=long
EOF
make_transcript "$T15/transcript.jsonl" "$LOG15"
out=$(printf '%s' "$(input_for "$T15" developer-phoenix-backend false sess15 "$T15/transcript.jsonl")" | RENDER_CHECK_CMD="" bash "$HOOK" 2>/dev/null || true)
[ ! -e "$T15/codegen/gate-pending/latest.flag" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T15: pre-seeded terminal latest.flag swept by hook entry\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: T15: pre-seeded terminal latest.flag not swept\n'
    fail=$((fail + 1))
}
assert_file_matches_jq "T15: short-gate verdict appended normally" 'select(.ev=="gate" and .verdict=="clear")' "$LOG15"
rm -rf "$T15"

# ── Test 18: A+B regression — A's transcript, B's newer log on disk → A's log ─
# B's log exists with newer mtime on disk, but transcript only records A.
# Gate verdict MUST be appended to A's log, not B's.
T18A=$(make_project)
T18B=$(make_project)
LOG_A="$T18A/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_A_cycle.jsonl"
write_planner_log "$LOG_A" <<'MD'
# Step A

## Plan

**Gate**: `true`
MD
# Create B's log with a newer mtime (sleep 1 to guarantee).
sleep 1
LOG_B="$T18B/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_B_cycle.jsonl"
write_planner_log "$LOG_B" <<'MD'
# Step B

## Plan

**Gate**: `true`
MD
# A's transcript only records A's log write.
make_transcript "$T18A/transcript.jsonl" "$LOG_A"
out=$(printf '%s' "$(input_for "$T18A" developer-phoenix-backend false sess18 "$T18A/transcript.jsonl")" | RENDER_CHECK_CMD="" bash "$HOOK" 2>/dev/null || true)
# A's log must have a clear gate event; B's log must NOT.
if jq -e 'select(.ev=="gate" and .verdict=="clear")' "$LOG_A" >/dev/null 2>&1 &&
    ! jq -e 'select(.ev=="gate" and .verdict=="clear")' "$LOG_B" >/dev/null 2>&1; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: A+B regression: verdict appended to A only\n'
    pass=$((pass + 1))
else
    printf 'FAIL: A+B regression: wrong log got verdict\n  A: %s\n  B: %s\n' "$(cat "$LOG_A")" "$(cat "$LOG_B")"
    fail=$((fail + 1))
fi
rm -rf "$T18A" "$T18B"

# ── Test 19: first failure → "attempt 1 — dev-fixable" in log ──────────────
T19=$(make_project)
LOG19="$T19/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_attempt1_cycle.jsonl"
write_planner_log "$LOG19" <<'MD'
# Step

## Plan

**Gate**: `false`
MD
make_transcript "$T19/transcript.jsonl" "$LOG19"
out=$(printf '%s' "$(input_for "$T19" developer-phoenix-backend false sess19 "$T19/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
assert_file_matches_jq "T19: first failure labels as attempt 1 dev-fixable" 'select(.ev=="gate" and (.result | test("attempt 1 — dev-fixable")))' "$LOG19"
rm -rf "$T19"

# ── Test 20: second failure (pre-seeded FAILED ❌) → "ROOT-CAUSE: route to planner" ─
T20=$(make_project)
LOG20="$T20/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_attempt2_cycle.jsonl"
write_planner_log "$LOG20" <<'MD'
# Step

## Plan

**Gate**: `false`
MD
jq -c -n '{ev:"gate",role:"dev-gate",verdict:"failed",gate:"false",mode:"short",result:"FAILED ❌ exit=1 (attempt 1 — dev-fixable)",detail:""}' >>"$LOG20"
make_transcript "$T20/transcript.jsonl" "$LOG20"
out=$(printf '%s' "$(input_for "$T20" developer-phoenix-backend false sess20 "$T20/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
assert_file_matches_jq "T20: second failure labels as ROOT-CAUSE: route to planner" 'select(.ev=="gate" and (.result | test("ROOT-CAUSE: route to planner")))' "$LOG20"
rm -rf "$T20"

# ── Test 21: no-op gate detection — make -v redirected, exit 0, no evidence ──
# Gate: `make -v >/dev/null 2>&1`
#   gate_runner=make (on PATH → passes :374-388 runner check)
#   expected_segs=1 (awk at :416 counts one `make ` segment)
#   output fully redirected → actual_segs=0 < 1 → no-op branch fires (:416-428)
#   make -v exits 0 → rc=0 path exercised deterministically
T21=$(make_project)
LOG21="$T21/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_noop_cycle.jsonl"
write_planner_log "$LOG21" <<'MD'
# Step

## Plan

**Gate**: `make -v >/dev/null 2>&1`
MD
make_transcript "$T21/transcript.jsonl" "$LOG21"
out=$(printf '%s' "$(input_for "$T21" developer-phoenix-backend false sess21 "$T21/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
assert_file_matches_jq "T21: no-op gate detected in step log" 'select(.ev=="gate" and (.result | test("FAILED ❌ no-op gate")))' "$LOG21"
assert_contains "T21: no-op gate emits block envelope" '"decision": "block"' "$out"
rm -rf "$T21"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
