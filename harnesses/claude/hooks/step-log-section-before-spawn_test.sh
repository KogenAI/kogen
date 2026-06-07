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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
