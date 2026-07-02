#!/usr/bin/env bash
# phoenix-dev-gate-concurrency_test.sh — concurrency and PID-reuse edge case tests.
#
# Tests: 8-10, 16, 17
# Covers: previous-PID-alive INCONCLUSIVE, dead-PID reaper sweep + new gate launch,
# mutex contention INCONCLUSIVE, live-PID flag preserved (no false sweep),
# reused-PID stale flag sweep prevents false lockout.

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

assert_file_contains() {
    local desc="$1"
    local needle="$2"
    local file="$3"
    if [ -f "$file" ] && grep -qF "$needle" "$file"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
make_transcript "$T8/transcript.jsonl" "$LOG8"
out=$(printf '%s' "$(input_for "$T8" developer-phoenix-backend false sess8 "$T8/transcript.jsonl")" | DEV_GATE_POLL_TIMEOUT_OVERRIDE=5 bash "$HOOK" 2>/dev/null || true)
kill "$prev_pid" 2>/dev/null || true
assert_file_contains "prev-alive: INCONCLUSIVE appended" "INCONCLUSIVE" "$LOG8"
assert_file_contains "prev-alive: reason is previous-gate-running" "previous-gate-running" "$LOG8"
# No new flag file should have been created for sess8.
[ ! -f "$T8/codegen/gate-pending/sess8.flag" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: prev-alive: no new flag created\n'
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
make_transcript "$T9/transcript.jsonl" "$LOG9"
out=$(printf '%s' "$(input_for "$T9" developer-phoenix-backend false sess9 "$T9/transcript.jsonl")" |
    DEV_GATE_POLL_TIMEOUT_OVERRIDE=10 PATH="$stub_bin9:$PATH" bash "$HOOK" 2>/dev/null || true)
# Orphan files should be swept (reaper runs in long-gate branch).
[ ! -f "$orphan_log" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: dead-pid: orphan .log swept\n'
    pass=$((pass + 1))
} || {
    printf 'FAIL: dead-pid: orphan .log not swept\n'
    fail=$((fail + 1))
}
# New gate launched and verdict produced.
[ -f "$T9/codegen/gate-pending/sess9.flag" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: dead-pid: new gate launched\n'
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
make_transcript "$T10/transcript.jsonl" "$LOG10"
out=$(printf '%s' "$(input_for "$T10" developer-phoenix-backend false sess10 "$T10/transcript.jsonl")" | DEV_GATE_POLL_TIMEOUT_OVERRIDE=5 bash "$HOOK" 2>/dev/null || true)
assert_file_contains "mutex: INCONCLUSIVE appended" "INCONCLUSIVE" "$LOG10"
assert_file_contains "mutex: reason is concurrent-launch" "concurrent-launch" "$LOG10"
rm -rf "$T10"

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
make_transcript "$T16/transcript.jsonl" "$LOG16"
out=$(printf '%s' "$(input_for "$T16" developer-phoenix-backend false sess16 "$T16/transcript.jsonl")" | DEV_GATE_POLL_TIMEOUT_OVERRIDE=5 bash "$HOOK" 2>/dev/null || true)
[ -e "$T16/codegen/gate-pending/latest.flag" ] && {
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T16: live-PID flag preserved (no false sweep)\n'
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
make_transcript "$T17/transcript.jsonl" "$LOG17"
out=$(printf '%s' "$(input_for "$T17" developer-phoenix-backend false sess17 "$T17/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
kill "$reused_pid" 2>/dev/null || true
# Without the sweep, the lockout would fire because PID is alive.
# With the sweep, the terminal flag is removed before the lockout check sees it.
if grep -qF "previous-gate-running" "$LOG17"; then
    printf 'FAIL: T17: false previous-gate-running lockout fired despite terminal flag\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: T17: sweep prevented false previous-gate-running lockout\n'
    pass=$((pass + 1))
fi
rm -rf "$T17"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
