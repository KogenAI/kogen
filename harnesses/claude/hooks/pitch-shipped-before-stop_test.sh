#!/usr/bin/env bash
# pitch-shipped-before-stop_test.sh — unit tests for pitch-shipped-before-stop.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/pitch-shipped-before-stop.sh"

pass=0
fail=0

assert_block() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected block\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        printf 'FAIL: %s — expected allow, got block\n  stdout: %s\n' "$desc" "$stdout"
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

make_transcript_with_pitch_and_log() {
    local transcript_path="$1"
    local log_path="$2"
    local pitch_path="$3"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$pitch_path" >>"$transcript_path"
}

make_transcript_log_only() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

mk_stop_input() {
    local session_id="$1"
    local transcript_path="$2"
    local cwd="$3"
    local last_msg="${4:-Work complete.}"
    local stop_active="${5:-false}"
    jq -n \
        --arg sid "$session_id" \
        --arg t "$transcript_path" \
        --arg c "$cwd" \
        --arg m "$last_msg" \
        --argjson sa "$stop_active" \
        '{"hook_event_name":"Stop","session_id":$sid,"transcript_path":$t,"cwd":$c,"last_assistant_message":$m,"stop_hook_active":$sa}'
}

# ── Test 1: block when committer-section + pitch in ready/ ───────────────────
T1=$(make_project)
PITCH1="$T1/codegen/pitches/ready/my-feature.md"
printf '# My Feature pitch\n' >"$PITCH1"
LOG1="$T1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG1" <<'MD'
## committer Section

Committed sha abc123.
MD
make_transcript_with_pitch_and_log "$T1/transcript.jsonl" "$LOG1" "$PITCH1"
out1=$(mk_stop_input "sess1" "$T1/transcript.jsonl" "$T1" | bash "$HOOK" 2>/dev/null || true)
assert_block "block: committer-section present + pitch in ready/" "$out1"
rm -rf "$T1"

# ── Test 2: allow when pitch already in shipped/ (not in ready/) ─────────────
T2=$(make_project)
PITCH2_SHIPPED="$T2/codegen/pitches/shipped/my-feature.md"
printf '# My Feature pitch\n' >"$PITCH2_SHIPPED"
# Transcript references the shipped path (pitch was moved before stop)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG2" <<'MD'
## committer Section

Committed.
MD
# Transcript references pitch in shipped/ not ready/
make_transcript_with_pitch_and_log "$T2/transcript.jsonl" "$LOG2" "$PITCH2_SHIPPED"
out2=$(mk_stop_input "sess2" "$T2/transcript.jsonl" "$T2" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: pitch already in shipped/" "$out2"
rm -rf "$T2"

# ── Test 3: allow when no pitch in transcript (free-form) ────────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG3" <<'MD'
## committer Section

Committed.
MD
make_transcript_log_only "$T3/transcript.jsonl" "$LOG3"
out3=$(mk_stop_input "sess3" "$T3/transcript.jsonl" "$T3" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: no pitch in transcript (free-form)" "$out3"
rm -rf "$T3"

# ── Test 4: allow when committer section absent ───────────────────────────────
T4=$(make_project)
PITCH4="$T4/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH4"
LOG4="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG4" <<'MD'
## reviewer-phoenix Section

QUALITY APPROVED
MD
make_transcript_with_pitch_and_log "$T4/transcript.jsonl" "$LOG4" "$PITCH4"
out4=$(mk_stop_input "sess4" "$T4/transcript.jsonl" "$T4" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: committer section absent (committer hasn't run yet)" "$out4"
rm -rf "$T4"

# ── Test 5: bypass CLAUDE_ROLE=dashboard-build ───────────────────────────────
T5=$(make_project)
PITCH5="$T5/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH5"
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG5" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T5/transcript.jsonl" "$LOG5" "$PITCH5"
out5=$(CLAUDE_ROLE=dashboard-build mk_stop_input "sess5" "$T5/transcript.jsonl" "$T5" | CLAUDE_ROLE=dashboard-build bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=dashboard-build bypass" "$out5"
rm -rf "$T5"

# ── Test 6: bypass CODEGEN_NO_AUTOSHIP=1 ─────────────────────────────────────
T6=$(make_project)
PITCH6="$T6/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH6"
LOG6="$T6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG6" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T6/transcript.jsonl" "$LOG6" "$PITCH6"
out6=$(mk_stop_input "sess6" "$T6/transcript.jsonl" "$T6" | CODEGEN_NO_AUTOSHIP=1 bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CODEGEN_NO_AUTOSHIP=1 bypass" "$out6"
rm -rf "$T6"

# ── Test 7: allow intent question (ends with ?) ──────────────────────────────
T7=$(make_project)
PITCH7="$T7/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH7"
LOG7="$T7/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG7" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T7/transcript.jsonl" "$LOG7" "$PITCH7"
out7=$(mk_stop_input "sess7" "$T7/transcript.jsonl" "$T7" "Should I proceed?" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: intent question (last message ends with ?)" "$out7"
rm -rf "$T7"

# ── Test 8: allow STOP_HOOK_ACTIVE=true ──────────────────────────────────────
T8=$(make_project)
PITCH8="$T8/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH8"
LOG8="$T8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG8" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T8/transcript.jsonl" "$LOG8" "$PITCH8"
out8=$(mk_stop_input "sess8" "$T8/transcript.jsonl" "$T8" "Done." true | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: STOP_HOOK_ACTIVE=true" "$out8"
rm -rf "$T8"

# ── Test 9: retry cap stops at attempt 2 ─────────────────────────────────────
T9=$(make_project)
PITCH9="$T9/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH9"
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG9" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T9/transcript.jsonl" "$LOG9" "$PITCH9"
COUNTER9="/tmp/claude-autoship-guard-sess9.count"
printf '2' >"$COUNTER9"
out9=$(mk_stop_input "sess9" "$T9/transcript.jsonl" "$T9" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: retry cap at 2 — hook exits without blocking" "$out9"
rm -f "$COUNTER9"
rm -rf "$T9"

# ── Test 10: allow when no transcript ────────────────────────────────────────
T10=$(make_project)
out10=$(mk_stop_input "sess10" "" "$T10" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: no transcript path — fail-open" "$out10"
rm -rf "$T10"

# ── Test 11: block increments counter on first attempt ───────────────────────
T11=$(make_project)
PITCH11="$T11/codegen/pitches/ready/increment-test.md"
printf '# Pitch\n' >"$PITCH11"
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG11" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T11/transcript.jsonl" "$LOG11" "$PITCH11"
COUNTER11="/tmp/claude-autoship-guard-sess11.count"
rm -f "$COUNTER11"
mk_stop_input "sess11" "$T11/transcript.jsonl" "$T11" | bash "$HOOK" >/dev/null 2>&1 || true
cnt=$(cat "$COUNTER11" 2>/dev/null || echo 0)
if [ "$cnt" = "1" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: counter incremented to 1 on first block\n'
    pass=$((pass + 1))
else
    printf 'FAIL: counter increment — expected 1, got %s\n' "$cnt"
    fail=$((fail + 1))
fi
rm -f "$COUNTER11"
rm -rf "$T11"

# ── Test 12: allow when intent regex matches (Blocked) ───────────────────────
T12=$(make_project)
PITCH12="$T12/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH12"
LOG12="$T12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG12" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T12/transcript.jsonl" "$LOG12" "$PITCH12"
out12=$(mk_stop_input "sess12" "$T12/transcript.jsonl" "$T12" "Blocked waiting for user input." | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: intent regex match (Blocked in message)" "$out12"
rm -rf "$T12"

# ── Test 13: second block attempt still blocks (before cap) ──────────────────
T13=$(make_project)
PITCH13="$T13/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH13"
LOG13="$T13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG13" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_pitch_and_log "$T13/transcript.jsonl" "$LOG13" "$PITCH13"
COUNTER13="/tmp/claude-autoship-guard-sess13.count"
printf '1' >"$COUNTER13"
out13=$(mk_stop_input "sess13" "$T13/transcript.jsonl" "$T13" | bash "$HOOK" 2>/dev/null || true)
assert_block "block: second attempt (count=1 < cap=2) still blocks" "$out13"
rm -f "$COUNTER13"
rm -rf "$T13"

# ── Test 14: allow when log unreadable (fail-open) ───────────────────────────
T14=$(make_project)
PITCH14="$T14/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH14"
# Transcript references a non-existent log
FAKE_LOG14="$T14/codegen/logging/nonexistent.md"
make_transcript_with_pitch_and_log "$T14/transcript.jsonl" "$FAKE_LOG14" "$PITCH14"
out14=$(mk_stop_input "sess14" "$T14/transcript.jsonl" "$T14" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: step log not readable — fail-open (no committer section)" "$out14"
rm -rf "$T14"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
