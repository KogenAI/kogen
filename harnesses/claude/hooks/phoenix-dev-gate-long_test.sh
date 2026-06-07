#!/usr/bin/env bash
# phoenix-dev-gate-long_test.sh — long-running gate scenario tests.
#
# Tests: 5, 11-14
# Covers: long-gate flag file shape, long-gate exit-0 ALL CLEAR, long-gate exit-1 FAILED,
# long-gate timeout INCONCLUSIVE, long-gate ALL CLEAR removes latest.flag.

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

# ── Test 5: long-gate flag file shape ───────────────────────────────────────
T5=$(make_project)
LOG="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_long.md"
cat >"$LOG" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
make_transcript "$T5/transcript.jsonl" "$LOG"
# Pre-empt: stub out `make` would actually run "make llm" forever. Instead,
# rely on the gate string going via `nohup bash -c "make llm > ..."` which
# fails fast in this temp dir (no Makefile). Either way the flag file is
# written before the gate completes. We just need to assert the flag exists
# and has the right keys.
out=$(printf '%s' "$(input_for "$T5" developer-phoenix-backend false sess-long "$T5/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
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

# ── Test 11: long gate exit 0 → ALL CLEAR ✅ ────────────────────────────────
T11=$(make_project)
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_pass.md"
# Create a stub `make` that exits 0 after 2s (mode=long because gate is "make llm").
# Prints a "make llm" line so the execution evidence check sees evidence.
stub_bin11=$(mktemp -d)
cat >"$stub_bin11/make" <<'SH'
#!/usr/bin/env bash
echo "make llm"
sleep 2
exit 0
SH
chmod +x "$stub_bin11/make"
cat >"$LOG11" <<'MD'
# Step

## Plan

**Gate**: `make llm`

MD
make_transcript "$T11/transcript.jsonl" "$LOG11"
out=$(printf '%s' "$(input_for "$T11" developer-phoenix-backend false sess11 "$T11/transcript.jsonl")" |
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
make_transcript "$T12/transcript.jsonl" "$LOG12"
out=$(printf '%s' "$(input_for "$T12" developer-phoenix-backend false sess12 "$T12/transcript.jsonl")" |
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
make_transcript "$T13/transcript.jsonl" "$LOG13"
# Use a 1-second poll timeout so the test completes quickly.
out=$(printf '%s' "$(input_for "$T13" developer-phoenix-backend false sess13 "$T13/transcript.jsonl")" |
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
echo "make llm"
exit 0
SH
chmod +x "$stub_bin14/make"
cat >"$LOG14" <<'MD'
# Step

## Plan

**Gate**: `make llm`
MD
make_transcript "$T14/transcript.jsonl" "$LOG14"
out=$(printf '%s' "$(input_for "$T14" developer-phoenix-backend false sess14 "$T14/transcript.jsonl")" |
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
