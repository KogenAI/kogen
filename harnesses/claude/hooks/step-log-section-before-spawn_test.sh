#!/usr/bin/env bash
# step-log-section-before-spawn_test.sh — unit tests for step-log-section-before-spawn.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/step-log-section-before-spawn.sh"

pass=0
fail=0

assert_deny() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        printf 'FAIL: %s — expected allow, got deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/codegen/logging"
    mkdir -p "$dir/codegen/pitches/ready"
    mkdir -p "$dir/codegen/pitches/shipped"
    printf '%s' "$dir"
}

make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

mk_agent_input() {
    local stype="$1"
    local transcript_path="$2"
    jq -n \
        --arg s "$stype" \
        --arg t "$transcript_path" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","transcript_path":$t}'
}

mk_agent_input_with_cwd() {
    local stype="$1"
    local transcript_path="$2"
    local cwd="$3"
    jq -n \
        --arg s "$stype" \
        --arg t "$transcript_path" \
        --arg c "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","cwd":$c,"transcript_path":$t}'
}

mk_non_agent_input() {
    local tool_name="$1"
    local transcript_path="$2"
    jq -n \
        --arg n "$tool_name" \
        --arg t "$transcript_path" \
        '{"hook_event_name":"PreToolUse","tool_name":$n,"tool_input":{"command":"ls"},"agent_id":"","agent_type":"","transcript_path":$t}'
}

# ── Test 1: deny when no step log in transcript ──────────────────────────────
T1=$(make_project)
# Transcript references no log file
FAKE_TRANSCRIPT="$T1/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT"
out1=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT" | bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: no step log in transcript (planner-phoenix)" "$out1"
rm -rf "$T1"

# ── Test 2: deny planner-phoenix when ## Plan header absent ─────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG2" <<'MD'
# Step 1 — test

**Started**: 2026-01-01T00:00:00Z

## Version Stamp

- context: abc
MD
make_transcript "$T2/transcript.jsonl" "$LOG2"
out2=$(mk_agent_input "planner-phoenix" "$T2/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: planner-phoenix — ## Plan header absent" "$out2"
rm -rf "$T2"

# ── Test 3: deny developer-phoenix-backend when its section header absent ────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG3" <<'MD'
# Step 1 — test

## Plan

planner wrote here
MD
make_transcript "$T3/transcript.jsonl" "$LOG3"
out3=$(mk_agent_input "developer-phoenix-backend" "$T3/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: developer-phoenix-backend — section header absent" "$out3"
rm -rf "$T3"

# ── Test 4: allow planner-phoenix when ## Plan header present (even empty) ───
T4=$(make_project)
LOG4="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG4" <<'MD'
# Step 1 — test

## Plan

MD
make_transcript "$T4/transcript.jsonl" "$LOG4"
out4=$(mk_agent_input "planner-phoenix" "$T4/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: planner-phoenix — ## Plan header present (empty body)" "$out4"
rm -rf "$T4"

# ── Test 5: allow developer-phoenix-backend with header present ───────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG5" <<'MD'
# Step 1 — test

## Plan

planner wrote here

## developer-phoenix-backend Section

MD
make_transcript "$T5/transcript.jsonl" "$LOG5"
out5=$(mk_agent_input "developer-phoenix-backend" "$T5/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-phoenix-backend — section header present" "$out5"
rm -rf "$T5"

# ── Test 6: allow developer-phoenix-frontend with header present ──────────────
T6=$(make_project)
LOG6="$T6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG6" <<'MD'
## developer-phoenix-frontend Section

MD
make_transcript "$T6/transcript.jsonl" "$LOG6"
out6=$(mk_agent_input "developer-phoenix-frontend" "$T6/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-phoenix-frontend — section header present" "$out6"
rm -rf "$T6"

# ── Test 7: allow developer-html with header present ─────────────────────────
T7=$(make_project)
LOG7="$T7/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG7" <<'MD'
## developer-html Section

MD
make_transcript "$T7/transcript.jsonl" "$LOG7"
out7=$(mk_agent_input "developer-html" "$T7/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-html — section header present" "$out7"
rm -rf "$T7"

# ── Test 8: allow reviewer-phoenix with header present ───────────────────────
T8=$(make_project)
LOG8="$T8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG8" <<'MD'
## reviewer-phoenix Section

MD
make_transcript "$T8/transcript.jsonl" "$LOG8"
out8=$(mk_agent_input "reviewer-phoenix" "$T8/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: reviewer-phoenix — section header present" "$out8"
rm -rf "$T8"

# ── Test 9: allow reviewer-static with header present ────────────────────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG9" <<'MD'
## reviewer-static Section

MD
make_transcript "$T9/transcript.jsonl" "$LOG9"
out9=$(mk_agent_input "reviewer-static" "$T9/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: reviewer-static — section header present" "$out9"
rm -rf "$T9"

# ── Test 10: allow context-curator with header present ───────────────────────
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG10" <<'MD'
## context-curator Section

MD
make_transcript "$T10/transcript.jsonl" "$LOG10"
out10=$(mk_agent_input "context-curator" "$T10/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: context-curator — section header present" "$out10"
rm -rf "$T10"

# ── Test 11: allow committer with header present ──────────────────────────────
T11=$(make_project)
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG11" <<'MD'
## committer Section

MD
make_transcript "$T11/transcript.jsonl" "$LOG11"
out11=$(mk_agent_input "committer" "$T11/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: committer — section header present" "$out11"
rm -rf "$T11"

# ── Test 12: allow non-Agent tool (Bash) unconditionally ─────────────────────
T12=$(make_project)
# Empty transcript — no log. But tool is Bash, not Agent.
FAKE_TRANSCRIPT12="$T12/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT12"
out12=$(mk_non_agent_input "Bash" "$FAKE_TRANSCRIPT12" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: non-Agent tool (Bash) — hook exits 0 unconditionally" "$out12"
rm -rf "$T12"

# ── Test 13: fail-open when transcript unreadable ────────────────────────────
T13=$(make_project)
# Pass a transcript path that does not exist.
out13=$(mk_agent_input "developer-phoenix-backend" "/nonexistent/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: transcript unreadable — fail-open" "$out13"
rm -rf "$T13"

# ── Test 14: allow developer-hugo with header present ────────────────────────
T14=$(make_project)
LOG14="$T14/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG14" <<'MD'
## developer-hugo Section

MD
make_transcript "$T14/transcript.jsonl" "$LOG14"
out14=$(mk_agent_input "developer-hugo" "$T14/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-hugo — section header present" "$out14"
rm -rf "$T14"

# ── Test 15: allow developer-vite with header present ────────────────────────
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG15" <<'MD'
## developer-vite Section

MD
make_transcript "$T15/transcript.jsonl" "$LOG15"
out15=$(mk_agent_input "developer-vite" "$T15/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: developer-vite — section header present" "$out15"
rm -rf "$T15"

# ── Test 16: filesystem fallback when transcript lags (managed build) ────────
# Simulates a print-mode build where the transcript is flushed asynchronously:
# the transcript has NO Write entry for the current step log, but the file
# exists on disk with the required section header. OCG_APPS_ROOT is set and
# CWD is under it, so the filesystem fallback should find the log and allow.
T16_APPS=$(mktemp -d)
T16="$T16_APPS/myapp"
mkdir -p "$T16/codegen/logging"
LOG16="$T16/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG16" <<'MD'
# Step 1 — test

## Plan

planner wrote here

## developer-phoenix-backend Section

MD
# Transcript has only an unrelated older Write entry — simulating transcript lag
FAKE_TRANSCRIPT16="$T16/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"codegen/logging/20240101_000000_old_session.md"}}]}}\n' \
    >"$FAKE_TRANSCRIPT16"
export OCG_APPS_ROOT="$T16_APPS"
out16=$(mk_agent_input_with_cwd "developer-phoenix-backend" "$FAKE_TRANSCRIPT16" "$T16" | bash "$HOOK" 2>/dev/null || true)
unset OCG_APPS_ROOT
assert_allow "allow: filesystem fallback when transcript lags in managed build" "$out16"
rm -rf "$T16_APPS"

# ── Test 17: no filesystem fallback outside managed build (no OCG_APPS_ROOT) ─
# Same setup as T16 (log on disk, transcript lags) but OCG_APPS_ROOT is unset.
# Should deny — strict transcript-bound resolution for interactive sessions.
T17=$(make_project)
LOG17="$T17/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG17" <<'MD'
# Step 1 — test

## developer-phoenix-backend Section

MD
FAKE_TRANSCRIPT17="$T17/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT17"
out17=$(
    unset OCG_APPS_ROOT 2>/dev/null
    mk_agent_input "developer-phoenix-backend" "$FAKE_TRANSCRIPT17" | bash "$HOOK" 2>/dev/null || true
)
assert_deny "deny: no fallback outside managed build (OCG_APPS_ROOT unset)" "$out17"
rm -rf "$T17"

# ── Test 18: filesystem fallback finds log but section header absent ──────────
# Simulates a print-mode build (OCG_APPS_ROOT set, CWD under it) where the
# transcript is completely empty (no Write entries for any log file, i.e. full
# transcript lag). The filesystem fallback resolves the most-recent log on disk.
# That log exists but lacks the required section header.
# The hook should DENY with the "append header" message — NOT the "create log"
# message — confirming the fallback resolved the log before checking the header.
T18_APPS=$(mktemp -d)
T18="$T18_APPS/myapp"
mkdir -p "$T18/codegen/logging"
LOG18="$T18/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG18" <<'MD'
# Step 1 — test

## Plan

planner wrote here
MD
# Transcript is empty — no Write entries at all — full transcript lag
FAKE_TRANSCRIPT18="$T18/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT18"
export OCG_APPS_ROOT="$T18_APPS"
out18=$(mk_agent_input_with_cwd "developer-phoenix-backend" "$FAKE_TRANSCRIPT18" "$T18" | bash "$HOOK" 2>/dev/null || true)
unset OCG_APPS_ROOT
assert_deny "deny: filesystem fallback finds log but section header absent — append header (not create log)" "$out18"
# Verify the deny message names the missing header (not the "create log" message)
if printf '%s' "$out18" | grep -q "append"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: test 18 deny names "append" (correct message)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: test 18 deny should mention "append" but got: %s\n' "$out18"
    fail=$((fail + 1))
fi
rm -rf "$T18_APPS"

# ── Test 19: allow shape role with no step log (investigative bypass) ─────────
T16=$(make_project)
FAKE_TRANSCRIPT16="$T16/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT16"
out16=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT16" | CLAUDE_ROLE=shape bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=shape — investigative bypass regardless of missing log" "$out16"
rm -rf "$T16"

# ── Test 20: allow debug role with no step log (investigative bypass) ─────────
T17=$(make_project)
FAKE_TRANSCRIPT17="$T17/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT17"
out17=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT17" | CLAUDE_ROLE=debug bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=debug — investigative bypass regardless of missing log" "$out17"
rm -rf "$T17"

# ── Test 21: allow ops role with no step log (investigative bypass) ───────────
T18=$(make_project)
FAKE_TRANSCRIPT18="$T18/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT18"
out18=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT18" | CLAUDE_ROLE=ops bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=ops — investigative bypass regardless of missing log" "$out18"
rm -rf "$T18"

# ── Test 22: deny unknown role with no step log (fail-closed) ─────────────────
T19=$(make_project)
FAKE_TRANSCRIPT19="$T19/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT19"
out19=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT19" | CLAUDE_ROLE=banana bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: CLAUDE_ROLE=banana — unknown role not bypassed, no log → deny" "$out19"
rm -rf "$T19"

# ── Test 20 (bug fix): deny when log path in transcript but file never created ─
# Transcript has a Write entry for a logging path, but the file does NOT exist.
# This was the fail-open bug: ! -r is true on absent files → old code allowed.
T20=$(make_project)
FAKE_TRANSCRIPT20="$T20/transcript.jsonl"
GHOST_LOG="$T20/codegen/logging/20260101_000000_test-session.md"
# Build transcript referencing the ghost log (file not created on disk).
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
    "$GHOST_LOG" >"$FAKE_TRANSCRIPT20"
out20=$(mk_agent_input "planner-phoenix" "$FAKE_TRANSCRIPT20" | bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: log path in transcript but file never created on disk" "$out20"
rm -rf "$T20"

# ── Test 21 (fail-open preserved): log exists but chmod 000 (unreadable) ───────
# Under root, chmod 000 is a no-op and the file remains readable. In that case
# the hook proceeds to check headers (deny for absent header). Either outcome
# (allow or deny) satisfies the invariant that the hook does NOT hard-deny on
# an existing-but-unreadable file. We assert: NOT a "file never created" deny.
T21=$(make_project)
LOG21="$T21/codegen/logging/20260101_000000_chmod-test.md"
printf '# Step\n' >"$LOG21"
make_transcript "$T21/transcript.jsonl" "$LOG21"
chmod 000 "$LOG21"
out21=$(mk_agent_input "planner-phoenix" "$T21/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
# The file exists on disk — must NOT trigger the "never created" deny message.
if printf '%s' "$out21" | grep -q 'never created'; then
    printf 'FAIL: Test 21 — existing chmod-000 log triggered the "never created" deny (should be fail-open or header-absent deny)\n  stdout: %s\n' "$out21"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: fail-open preserved: chmod-000 log does not trigger never-created deny\n'
    pass=$((pass + 1))
fi
chmod 644 "$LOG21" 2>/dev/null || true
rm -rf "$T21"

# ── Forbidden-type skip guard tests (e–j) ─────────────────────────────────────

# Test 22e: build-mode (no CLAUDE_ROLE) + Plan, no step log → ALLOW (skip guard fires)
T22=$(make_project)
FAKE_TRANSCRIPT22="$T22/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT22"
out22=$(mk_agent_input "Plan" "$FAKE_TRANSCRIPT22" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + Plan — skip guard defers to allowlist, no header demand" "$out22"
rm -rf "$T22"

# Test 22f: build-mode + empty subagent_type → ALLOW (skip guard fires)
T23=$(make_project)
FAKE_TRANSCRIPT23="$T23/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT23"
out23=$(mk_agent_input "" "$FAKE_TRANSCRIPT23" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + empty subagent_type — skip guard defers to allowlist" "$out23"
rm -rf "$T23"

# Test 22g: build-mode + general-purpose → ALLOW (skip guard fires)
T24=$(make_project)
FAKE_TRANSCRIPT24="$T24/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT24"
out24=$(mk_agent_input "general-purpose" "$FAKE_TRANSCRIPT24" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + general-purpose — skip guard defers to allowlist" "$out24"
rm -rf "$T24"

# Test 22h: build-mode + statusline-setup → ALLOW (skip guard fires)
T25=$(make_project)
FAKE_TRANSCRIPT25="$T25/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT25"
out25=$(mk_agent_input "statusline-setup" "$FAKE_TRANSCRIPT25" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + statusline-setup — skip guard defers to allowlist" "$out25"
rm -rf "$T25"

# Test 22i: build-mode + Explore → ALLOW (skip guard fires — allowlist will deny)
T26=$(make_project)
FAKE_TRANSCRIPT26="$T26/transcript.jsonl"
printf '' >"$FAKE_TRANSCRIPT26"
out26=$(mk_agent_input "Explore" "$FAKE_TRANSCRIPT26" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: build + Explore — skip guard defers to allowlist" "$out26"
rm -rf "$T26"

# Test 22j: REGRESSION — build-mode + developer-phoenix-backend with log present but section header ABSENT
# Must still DENY (skip guard must NOT over-skip legal types)
T27=$(make_project)
LOG27="$T27/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_regression.md"
cat >"$LOG27" <<'MD'
# Step 1 — regression

## Plan

planner content only — no developer section header
MD
make_transcript "$T27/transcript.jsonl" "$LOG27"
out27=$(mk_agent_input "developer-phoenix-backend" "$T27/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_deny "deny: REGRESSION — build + developer-phoenix-backend, log present but section header absent" "$out27"
rm -rf "$T27"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
