#!/usr/bin/env bash
# phoenix-dev-gate_test.sh — unit tests for phoenix-dev-gate.sh
#
# Covers: short-gate-success (no block), short-gate-failure (block),
# long-gate-flag-file-shape, planner-gate-wins, no-step-log graceful exit,
# stop_hook_active short-circuit, non-developer agent_type no-op.

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
    local agent_type="${2:-developer-phoenix-backend}"
    local stop_active="${3:-false}"
    local sid="${4:-sess1}"
    cat <<JSON
{"hook_event_name":"SubagentStop","agent_type":"$agent_type","agent_id":"abc","session_id":"$sid","cwd":"$cwd","stop_hook_active":$stop_active}
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
out=$(printf '%s' "$(input_for "$T5" developer-phoenix-backend false sess-long)" | bash "$HOOK" 2>/dev/null || true)
sleep 0.5
flag="$T5/codegen/gate-pending/sess-long.flag"
assert_file_contains "long-gate flag has gate=" "gate=make llm" "$flag"
assert_file_contains "long-gate flag has pid=" "pid=" "$flag"
assert_file_contains "long-gate flag has log=" "log=" "$flag"
assert_file_contains "long-gate flag has exitcode_file=" "exitcode_file=" "$flag"
assert_file_contains "long-gate flag has mode=long" "mode=long" "$flag"
assert_file_contains "long-gate flag has session_id" "session_id=sess-long" "$flag"
# latest.flag is removed after long-gate completion (invariant: exists ⇔ in flight).
# The per-session flag (sess-long.flag) still exists; only latest.flag is unlinked.
[ ! -e "$T5/codegen/gate-pending/latest.flag" ] && {
    printf 'PASS: latest.flag removed after long-gate completion\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: latest.flag still exists after long-gate completion\n'
    fail=$((fail + 1))
}
# The hook now blocks and polls — with no Makefile present, `make llm` fails
# fast and the verdict should be FAILED (or the flag file exists before verdict).
# We assert the flag file shape and that a verdict was appended (not placeholder).
assert_file_contains "long-gate verdict dev-gate section appended" "dev-gate Section" "$LOG"
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

# ── Test 8: previous PID alive → INCONCLUSIVE previous-gate-running ─────────
T8=$(make_project)
LOG8="$T8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_prevpid.md"
cat >"$LOG8" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
mkdir -p "$T8/codegen/gate-pending"
# Start a long-lived background process to stand in as the "previous gate".
sleep 600 &
prev_pid=$!
cat >"$T8/codegen/gate-pending/latest.flag" <<EOF
gate=make llm
pid=$prev_pid
log=$T8/codegen/gate-pending/old.log
exitcode_file=$T8/codegen/gate-pending/old.log.exitcode
started_at=2026-01-01T00:00:00Z
session_id=oldsession
mode=long
EOF
out=$(printf '%s' "$(input_for "$T8" developer-phoenix-backend false sess8)" | DEV_GATE_POLL_TIMEOUT_OVERRIDE=5 bash "$HOOK" 2>/dev/null || true)
kill "$prev_pid" 2>/dev/null || true
assert_file_contains "prev-alive: INCONCLUSIVE appended" "INCONCLUSIVE" "$LOG8"
assert_file_contains "prev-alive: reason is previous-gate-running" "previous-gate-running" "$LOG8"
# No new flag file should have been created for sess8.
[ ! -f "$T8/codegen/gate-pending/sess8.flag" ] && {
    printf 'PASS: prev-alive: no new flag created\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: prev-alive: new flag was unexpectedly created\n'
    fail=$((fail + 1))
}
rm -rf "$T8"

# ── Test 9: previous PID dead → reaper sweeps orphan files, new gate launches
# Uses a long-mode gate so the hook enters the long-gate branch where the reaper lives.
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_deadpid.md"
# Stub `make` exits 0 immediately so the poll loop completes quickly.
stub_bin9=$(mktemp -d)
cat >"$stub_bin9/make" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$stub_bin9/make"
cat >"$LOG9" <<'MD'
# Step

## Plan

**Gate**: `make llm`

MD
mkdir -p "$T9/codegen/gate-pending"
# Write latest.flag pointing to a dead PID (99999 is reliably dead).
cat >"$T9/codegen/gate-pending/latest.flag" <<'EOF'
gate=make llm
pid=99999
log=/tmp/nonexistent.log
exitcode_file=/tmp/nonexistent.log.exitcode
started_at=2026-01-01T00:00:00Z
session_id=oldsession
mode=long
EOF
# Create orphan log/exitcode files and backdate them > 24h.
orphan_log="$T9/codegen/gate-pending/oldsession-20240101T000000Z.log"
orphan_ec="${orphan_log}.exitcode"
touch "$orphan_log" "$orphan_ec"
# macOS: touch -t uses YYYYMMDDHHMM; GNU: touch -d "2 days ago".
two_days_ago=$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d "2 days ago" +%Y%m%d%H%M 2>/dev/null || echo "202401010000")
touch -t "$two_days_ago" "$orphan_log" "$orphan_ec" 2>/dev/null || true
out=$(printf '%s' "$(input_for "$T9" developer-phoenix-backend false sess9)" |
    DEV_GATE_POLL_TIMEOUT_OVERRIDE=10 PATH="$stub_bin9:$PATH" bash "$HOOK" 2>/dev/null || true)
# Orphan files should be swept (reaper runs in long-gate branch).
[ ! -f "$orphan_log" ] && {
    printf 'PASS: dead-pid: orphan .log swept\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: dead-pid: orphan .log not swept\n'
    fail=$((fail + 1))
}
# New gate launched and verdict produced.
[ -f "$T9/codegen/gate-pending/sess9.flag" ] && {
    printf 'PASS: dead-pid: new gate launched\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: dead-pid: new gate not launched\n'
    fail=$((fail + 1))
}
rm -rf "$T9" "$stub_bin9"

# ── Test 10: mutex contention → INCONCLUSIVE concurrent-launch ──────────────
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_mutex.md"
cat >"$LOG10" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
mkdir -p "$T10/codegen/gate-pending/.launch.lock"
# Write a live PID into the lock so stale-lock recovery does not remove it.
echo "$$" >"$T10/codegen/gate-pending/.launch.lock/launched_pid"
out=$(printf '%s' "$(input_for "$T10" developer-phoenix-backend false sess10)" | DEV_GATE_POLL_TIMEOUT_OVERRIDE=5 bash "$HOOK" 2>/dev/null || true)
assert_file_contains "mutex: INCONCLUSIVE appended" "INCONCLUSIVE" "$LOG10"
assert_file_contains "mutex: reason is concurrent-launch" "concurrent-launch" "$LOG10"
rm -rf "$T10"

# ── Test 11: long gate exit 0 → ALL CLEAR ✅ ────────────────────────────────
T11=$(make_project)
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_pass.md"
# Create a stub `make` that exits 0 after 2s (mode=long because gate is "make llm").
stub_bin11=$(mktemp -d)
cat >"$stub_bin11/make" <<'SH'
#!/usr/bin/env bash
sleep 2
exit 0
SH
chmod +x "$stub_bin11/make"
cat >"$LOG11" <<'MD'
# Step

## Plan

**Gate**: `make llm`

MD
out=$(printf '%s' "$(input_for "$T11" developer-phoenix-backend false sess11)" |
    DEV_GATE_POLL_TIMEOUT_OVERRIDE=10 PATH="$stub_bin11:$PATH" bash "$HOOK" 2>/dev/null || true)
assert_file_contains "long-gate exit-0: ALL CLEAR appended" "ALL CLEAR" "$LOG11"
rm -rf "$T11" "$stub_bin11"

# ── Test 12: long gate exit 1 → FAILED ❌ ───────────────────────────────────
T12=$(make_project)
LOG12="$T12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_fail_long.md"
# Create a stub `make` that exits 1 after 2s.
stub_bin12=$(mktemp -d)
cat >"$stub_bin12/make" <<'SH'
#!/usr/bin/env bash
sleep 2
exit 1
SH
chmod +x "$stub_bin12/make"
cat >"$LOG12" <<'MD'
# Step

## Plan

**Gate**: `make llm`

MD
out=$(printf '%s' "$(input_for "$T12" developer-phoenix-backend false sess12)" |
    DEV_GATE_POLL_TIMEOUT_OVERRIDE=10 PATH="$stub_bin12:$PATH" bash "$HOOK" 2>/dev/null || true)
assert_file_contains "long-gate exit-1: FAILED appended" "FAILED" "$LOG12"
rm -rf "$T12" "$stub_bin12"

# ── Test 13: long gate timeout → INCONCLUSIVE timeout-exceeded ───────────────
T13=$(make_project)
LOG13="$T13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_timeout.md"
# Create a stub `make` that sleeps for 30s so the poll times out.
# This must be in a bin dir that shadows the real `make` for the hook subprocess.
stub_bin13=$(mktemp -d)
cat >"$stub_bin13/make" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$stub_bin13/make"
cat >"$LOG13" <<'MD'
# Step

## Plan

**Gate**: `make llm`

MD
# Use a 1-second poll timeout so the test completes quickly.
out=$(printf '%s' "$(input_for "$T13" developer-phoenix-backend false sess13)" |
    DEV_GATE_POLL_TIMEOUT_OVERRIDE=1 PATH="$stub_bin13:$PATH" bash "$HOOK" 2>/dev/null || true)
assert_file_contains "timeout: INCONCLUSIVE appended" "INCONCLUSIVE" "$LOG13"
assert_file_contains "timeout: reason is timeout-exceeded" "timeout-exceeded" "$LOG13"
# Cleanup background sleep (stub make ran in nohup subprocess).
pkill -f "sleep 30" 2>/dev/null || true
rm -rf "$T13" "$stub_bin13"

# ── Test 14: long-gate ALL CLEAR removes latest.flag ────────────────────────
T14=$(make_project)
LOG14="$T14/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_sweep_allclear.md"
stub_bin14=$(mktemp -d)
cat >"$stub_bin14/make" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$stub_bin14/make"
cat >"$LOG14" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
out=$(printf '%s' "$(input_for "$T14" developer-phoenix-backend false sess14)" |
    DEV_GATE_POLL_TIMEOUT_OVERRIDE=10 PATH="$stub_bin14:$PATH" bash "$HOOK" 2>/dev/null || true)
assert_file_contains "T14: long-gate ALL CLEAR appended" "ALL CLEAR" "$LOG14"
[ ! -e "$T14/codegen/gate-pending/latest.flag" ] && {
    printf 'PASS: T14: latest.flag removed after long-gate completion\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: T14: latest.flag still exists after long-gate completion\n'
    fail=$((fail + 1))
}
rm -rf "$T14" "$stub_bin14"

# ── Test 15: short-gate sweeps pre-seeded terminal flag ─────────────────────
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_sweep_short.md"
cat >"$LOG15" <<'MD'
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
out=$(printf '%s' "$(input_for "$T15" developer-phoenix-backend false sess15)" | bash "$HOOK" 2>/dev/null || true)
[ ! -e "$T15/codegen/gate-pending/latest.flag" ] && {
    printf 'PASS: T15: pre-seeded terminal latest.flag swept by hook entry\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: T15: pre-seeded terminal latest.flag not swept\n'
    fail=$((fail + 1))
}
assert_file_contains "T15: short-gate verdict appended normally" "ALL CLEAR" "$LOG15"
rm -rf "$T15"

# ── Test 16: live PID + absent exitcode_file → flag preserved ───────────────
T16=$(make_project)
LOG16="$T16/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_sweep_live.md"
cat >"$LOG16" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
mkdir -p "$T16/codegen/gate-pending"
nonexistent_ec="/tmp/nonexistent-dev-gate-test-$$-$(date -u +%s).exitcode"
rm -f "$nonexistent_ec"
cat >"$T16/codegen/gate-pending/latest.flag" <<EOF
gate=make llm
pid=$$
log=/tmp/nonexistent-dev-gate-test.log
exitcode_file=$nonexistent_ec
started_at=2026-01-01T00:00:00Z
session_id=livesession
mode=long
EOF
out=$(printf '%s' "$(input_for "$T16" developer-phoenix-backend false sess16)" | DEV_GATE_POLL_TIMEOUT_OVERRIDE=5 bash "$HOOK" 2>/dev/null || true)
[ -e "$T16/codegen/gate-pending/latest.flag" ] && {
    printf 'PASS: T16: live-PID flag preserved (no false sweep)\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: T16: live-PID flag unexpectedly swept\n'
    fail=$((fail + 1))
}
rm -rf "$T16"

# ── Test 17: reused-PID stale flag → sweep prevents false lockout ───────────
T17=$(make_project)
LOG17="$T17/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_sweep_reused.md"
cat >"$LOG17" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
mkdir -p "$T17/codegen/gate-pending"
# Spawn a long-lived process to simulate a reused PID.
sleep 600 &
reused_pid=$!
# Seed a terminal exitcode file — gate finished, but coincidentally that PID is now in use.
ec17="$T17/codegen/gate-pending/oldsession-reused.log.exitcode"
echo 0 >"$ec17"
cat >"$T17/codegen/gate-pending/latest.flag" <<EOF
gate=make llm
pid=$reused_pid
log=$T17/codegen/gate-pending/oldsession-reused.log
exitcode_file=$ec17
started_at=2026-01-01T00:00:00Z
session_id=oldsession
mode=long
EOF
out=$(printf '%s' "$(input_for "$T17" developer-phoenix-backend false sess17)" | bash "$HOOK" 2>/dev/null || true)
kill "$reused_pid" 2>/dev/null || true
# Without the sweep, the lockout would fire because PID is alive.
# With the sweep, the terminal flag is removed before the lockout check sees it.
if grep -qF "previous-gate-running" "$LOG17"; then
    printf 'FAIL: T17: false previous-gate-running lockout fired despite terminal flag\n'
    fail=$((fail + 1))
else
    printf 'PASS: T17: sweep prevented false previous-gate-running lockout\n'
    pass=$((pass + 1))
fi
rm -rf "$T17"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
