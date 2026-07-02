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

make_transcript_with_log() {
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

# ── Test 1: block when slug-match + committer-section + pitch in ready/ ──────
T1=$(make_project)
PITCH1="$T1/codegen/pitches/ready/my-feature.md"
printf '# My Feature pitch\n' >"$PITCH1"
LOG1="$T1/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG1" <<'MD'
## committer Section

Committed sha abc123.
MD
make_transcript_with_log "$T1/transcript.jsonl" "$LOG1"
out1=$(mk_stop_input "sess1" "$T1/transcript.jsonl" "$T1" | bash "$HOOK" 2>/dev/null || true)
assert_block "block: slug-match + committer-section + pitch in ready/" "$out1"
rm -rf "$T1"

# ── Test 2: allow when pitch already in shipped/ (not in ready/) ─────────────
T2=$(make_project)
PITCH2_SHIPPED="$T2/codegen/pitches/shipped/my-feature.md"
printf '# My Feature pitch\n' >"$PITCH2_SHIPPED"
LOG2="$T2/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG2" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T2/transcript.jsonl" "$LOG2"
out2=$(mk_stop_input "sess2" "$T2/transcript.jsonl" "$T2" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: pitch already in shipped/ (not in ready/)" "$out2"
rm -rf "$T2"

# ── Test 3: allow when no pitch in ready/ (free-form log) ────────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG3" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T3/transcript.jsonl" "$LOG3"
out3=$(mk_stop_input "sess3" "$T3/transcript.jsonl" "$T3" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: slug-matched pitch not in ready/ (nothing to ship)" "$out3"
rm -rf "$T3"

# ── Test 4: allow when committer section absent ───────────────────────────────
T4=$(make_project)
PITCH4="$T4/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH4"
LOG4="$T4/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG4" <<'MD'
## reviewer-phoenix Section

QUALITY APPROVED
MD
make_transcript_with_log "$T4/transcript.jsonl" "$LOG4"
out4=$(mk_stop_input "sess4" "$T4/transcript.jsonl" "$T4" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: committer section absent (committer hasn't run yet)" "$out4"
rm -rf "$T4"

# ── Test 5: bypass CLAUDE_ROLE=dashboard-build ───────────────────────────────
T5=$(make_project)
PITCH5="$T5/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH5"
LOG5="$T5/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG5" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T5/transcript.jsonl" "$LOG5"
out5=$(CLAUDE_ROLE=dashboard-build mk_stop_input "sess5" "$T5/transcript.jsonl" "$T5" | CLAUDE_ROLE=dashboard-build bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CLAUDE_ROLE=dashboard-build bypass" "$out5"
rm -rf "$T5"

# ── Test 6: bypass CODEGEN_NO_AUTOSHIP=1 ─────────────────────────────────────
T6=$(make_project)
PITCH6="$T6/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH6"
LOG6="$T6/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG6" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T6/transcript.jsonl" "$LOG6"
out6=$(mk_stop_input "sess6" "$T6/transcript.jsonl" "$T6" | CODEGEN_NO_AUTOSHIP=1 bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: CODEGEN_NO_AUTOSHIP=1 bypass" "$out6"
rm -rf "$T6"

# ── Test 7: allow intent question (ends with ?) ──────────────────────────────
T7=$(make_project)
PITCH7="$T7/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH7"
LOG7="$T7/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG7" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T7/transcript.jsonl" "$LOG7"
out7=$(mk_stop_input "sess7" "$T7/transcript.jsonl" "$T7" "Should I proceed?" | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: intent question (last message ends with ?)" "$out7"
rm -rf "$T7"

# ── Test 8: allow STOP_HOOK_ACTIVE=true ──────────────────────────────────────
T8=$(make_project)
PITCH8="$T8/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH8"
LOG8="$T8/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG8" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T8/transcript.jsonl" "$LOG8"
out8=$(mk_stop_input "sess8" "$T8/transcript.jsonl" "$T8" "Done." true | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: STOP_HOOK_ACTIVE=true" "$out8"
rm -rf "$T8"

# ── Test 9: retry cap stops at attempt 2 ─────────────────────────────────────
T9=$(make_project)
PITCH9="$T9/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH9"
LOG9="$T9/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG9" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T9/transcript.jsonl" "$LOG9"
COUNTER9="/tmp/claude-autoship-guard-sess9.count"
printf '%s\n2' "$LOG9" >"$COUNTER9"
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
LOG11="$T11/codegen/logging/20260601_123456_increment-test_session.md"
cat >"$LOG11" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T11/transcript.jsonl" "$LOG11"
COUNTER11="/tmp/claude-autoship-guard-sess11.count"
rm -f "$COUNTER11"
mk_stop_input "sess11" "$T11/transcript.jsonl" "$T11" | bash "$HOOK" >/dev/null 2>&1 || true
cnt=$(sed -n '2p' "$COUNTER11" 2>/dev/null || echo 0)
if [ "$cnt" = "1" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: counter incremented to 1 on first block (two-line format)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: counter increment — expected line2=1, got %s\n' "$cnt"
    fail=$((fail + 1))
fi
rm -f "$COUNTER11"
rm -rf "$T11"

# ── Test 12: allow when intent regex matches (Blocked) ───────────────────────
T12=$(make_project)
PITCH12="$T12/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH12"
LOG12="$T12/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG12" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T12/transcript.jsonl" "$LOG12"
out12=$(mk_stop_input "sess12" "$T12/transcript.jsonl" "$T12" "Blocked waiting for user input." | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: intent regex match (Blocked in message)" "$out12"
rm -rf "$T12"

# ── Test 13: second block attempt still blocks (before cap) ──────────────────
T13=$(make_project)
PITCH13="$T13/codegen/pitches/ready/my-feature.md"
printf '# Pitch\n' >"$PITCH13"
LOG13="$T13/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG13" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T13/transcript.jsonl" "$LOG13"
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
FAKE_LOG14="$T14/codegen/logging/20260601_123456_my-feature_session.md"
make_transcript_with_log "$T14/transcript.jsonl" "$FAKE_LOG14"
out14=$(mk_stop_input "sess14" "$T14/transcript.jsonl" "$T14" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: step log not readable — fail-open (no committer section)" "$out14"
rm -rf "$T14"

# ── Test 15: slug-match + committer-section + pitch-not-in-ready/ → allow ────
# Incident case: build session for pitch X; unrelated pitch Y sits in ready/.
# New logic: only ships the pitch matching THIS session's slug (X), not Y.
T15=$(make_project)
PITCH_Y="$T15/codegen/pitches/ready/unrelated-pitch.md"
printf '# Unrelated pitch Y\n' >"$PITCH_Y"
# Log slug is "foo" — matches ready/foo.md, NOT ready/unrelated-pitch.md
LOG15="$T15/codegen/logging/20260601_123456_foo_session.md"
cat >"$LOG15" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T15/transcript.jsonl" "$LOG15"
out15=$(mk_stop_input "sess15" "$T15/transcript.jsonl" "$T15" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: slug pitch (foo.md) not in ready/ — unrelated pitch not shipped" "$out15"
rm -rf "$T15"

# ── Test 16: free-form log (no slug segment) + pitch in ready/ → allow ───────
T16=$(make_project)
PITCH16="$T16/codegen/pitches/ready/anything.md"
printf '# Anything\n' >"$PITCH16"
# Log name has no slug: <ts>_session.md (no slug between ts and _session)
LOG16="$T16/codegen/logging/20260601_123456_session.md"
cat >"$LOG16" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T16/transcript.jsonl" "$LOG16"
out16=$(mk_stop_input "sess16" "$T16/transcript.jsonl" "$T16" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: free-form log (no slug) — not pitch-driven, skip" "$out16"
rm -rf "$T16"

# ── Test 17: multi-step log (not _session form) + pitch in ready/ → allow ────
T17=$(make_project)
PITCH17="$T17/codegen/pitches/ready/foo.md"
printf '# Foo\n' >"$PITCH17"
# Log name is step form, not session form: <ts>_step1_foo.md
LOG17="$T17/codegen/logging/20260601_123456_step1_foo.md"
cat >"$LOG17" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T17/transcript.jsonl" "$LOG17"
out17=$(mk_stop_input "sess17" "$T17/transcript.jsonl" "$T17" | bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: multi-step log (not _session form) — skip" "$out17"
rm -rf "$T17"

# ── Test 18: underscore-bearing slug + pitch in ready/ → block ───────────────
T18=$(make_project)
PITCH18="$T18/codegen/pitches/ready/stop_resume_auto.md"
printf '# Stop resume auto\n' >"$PITCH18"
LOG18="$T18/codegen/logging/20260601_123456_stop_resume_auto_session.md"
cat >"$LOG18" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T18/transcript.jsonl" "$LOG18"
out18=$(mk_stop_input "sess18" "$T18/transcript.jsonl" "$T18" | bash "$HOOK" 2>/dev/null || true)
assert_block "block: underscore-bearing slug (stop_resume_auto) extracts correctly" "$out18"
rm -rf "$T18"

# ── Test 19: slug-match + committer-section + pitch in ready/ → block confirms slug in message ──
T19=$(make_project)
PITCH19="$T19/codegen/pitches/ready/my-pitch.md"
printf '# My pitch\n' >"$PITCH19"
LOG19="$T19/codegen/logging/20260601_123456_my-pitch_session.md"
cat >"$LOG19" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T19/transcript.jsonl" "$LOG19"
out19=$(mk_stop_input "sess19" "$T19/transcript.jsonl" "$T19" | bash "$HOOK" 2>/dev/null || true)
if printf '%s' "$out19" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' &&
    printf '%s' "$out19" | grep -qF 'my-pitch.md'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: block message contains slug filename\n'
    pass=$((pass + 1))
else
    printf 'FAIL: block message should contain slug filename my-pitch.md\n  stdout: %s\n' "$out19"
    fail=$((fail + 1))
fi
rm -rf "$T19"

# ── Test 20: COMMITTED stamp written when committer section present ───────────
T20=$(make_project)
PITCH20="$T20/codegen/pitches/shipped/my-feature.md" # pitch already shipped → allow stop
printf '# My Feature\n' >"$PITCH20"
LOG20="$T20/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG20" <<'MD'
## committer Section

Committed sha abc123.
MD
make_transcript_with_log "$T20/transcript.jsonl" "$LOG20"
out20=$(mk_stop_input "sess20" "$T20/transcript.jsonl" "$T20" | bash "$HOOK" 2>/dev/null || true)
# Check cycle-state.json was written with state=COMMITTED
cs_state20=""
cs_file20="$T20/codegen/gate-pending/cycle-state.json"
if [ -f "$cs_file20" ]; then
    cs_state20=$(jq -r '.state // ""' "$cs_file20" 2>/dev/null || printf '')
fi
if [ "$cs_state20" = "COMMITTED" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: COMMITTED stamp written when committer section present\n'
    pass=$((pass + 1))
else
    printf 'FAIL: COMMITTED stamp missing — expected state=COMMITTED, got: %s\n' "$cs_state20"
    fail=$((fail + 1))
fi
rm -rf "$T20"

# ── Test 21: no COMMITTED stamp when committer section absent ────────────────
T21=$(make_project)
PITCH21="$T21/codegen/pitches/ready/my-feature.md"
printf '# My Feature\n' >"$PITCH21"
LOG21="$T21/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG21" <<'MD'
## reviewer-phoenix Section

Reviewed.
MD
make_transcript_with_log "$T21/transcript.jsonl" "$LOG21"
out21=$(mk_stop_input "sess21" "$T21/transcript.jsonl" "$T21" | bash "$HOOK" 2>/dev/null || true)
cs_file21="$T21/codegen/gate-pending/cycle-state.json"
if [ ! -f "$cs_file21" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: no COMMITTED stamp when committer section absent\n'
    pass=$((pass + 1))
else
    cs_state21=$(jq -r '.state // ""' "$cs_file21" 2>/dev/null || printf '')
    printf 'FAIL: unexpected cycle-state.json written (state=%s) when committer absent\n' "$cs_state21"
    fail=$((fail + 1))
fi
rm -rf "$T21"

# ── Test 22: CODEGEN_BUILD_NON_INTERACTIVE suppresses intent escape → block ───
T22=$(make_project)
PITCH22="$T22/codegen/pitches/ready/my-feature.md"
printf '# My Feature\n' >"$PITCH22"
LOG22="$T22/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG22" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T22/transcript.jsonl" "$LOG22"
out22=$(mk_stop_input "sess22" "$T22/transcript.jsonl" "$T22" "Should I continue?" | CODEGEN_BUILD_NON_INTERACTIVE=1 bash "$HOOK" 2>/dev/null || true)
assert_block "block: CODEGEN_BUILD_NON_INTERACTIVE=1 suppresses intent escape (headless)" "$out22"
rm -rf "$T22"

# ── Test 23: interactive still allows intent question (regression guard) ──────
T23=$(make_project)
PITCH23="$T23/codegen/pitches/ready/my-feature.md"
printf '# My Feature\n' >"$PITCH23"
LOG23="$T23/codegen/logging/20260601_123456_my-feature_session.md"
cat >"$LOG23" <<'MD'
## committer Section

Committed.
MD
make_transcript_with_log "$T23/transcript.jsonl" "$LOG23"
out23=$(mk_stop_input "sess23" "$T23/transcript.jsonl" "$T23" "Should I continue?" | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true)
assert_allow "allow: no CODEGEN_BUILD_NON_INTERACTIVE → intent escape still works (interactive)" "$out23"
rm -rf "$T23"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
