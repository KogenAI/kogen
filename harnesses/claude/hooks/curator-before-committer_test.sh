#!/usr/bin/env bash
# curator-before-committer_test.sh — unit tests for curator-before-committer.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/curator-before-committer.sh"

pass=0
fail=0

assert_deny() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        printf 'PASS: %s\n' "$desc"
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
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/codegen/logging"
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

# ── Test 1: committer blocked when reviewer present, curator absent ──────────
T1=$(make_project)
LOG1="$T1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG1" <<'MD'
## developer-phoenix-backend Section

result here

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅
MD
make_transcript "$T1/transcript.jsonl" "$LOG1"
out1=$(mk_agent_input "committer" "$T1/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_deny "committer blocked: reviewer present, curator absent" "$out1"
rm -rf "$T1"

# ── Test 2: committer allowed when context-curator section exists ────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG2" <<'MD'
## developer-phoenix-backend Section

result here

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅

## context-curator Section

Files updated.
MD
make_transcript "$T2/transcript.jsonl" "$LOG2"
out2=$(mk_agent_input "committer" "$T2/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "committer allowed: context-curator section present" "$out2"
rm -rf "$T2"

# ── Test 3: non-committer subagents allowed unconditionally ─────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1_test.md"
cat >"$LOG3" <<'MD'
## developer-phoenix-backend Section

result here

## dev-gate Section

ALL CLEAR ✅

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅
MD
make_transcript "$T3/transcript.jsonl" "$LOG3"

for stype in "planner-phoenix" "developer-phoenix-backend" "reviewer-phoenix" "context-curator"; do
    out_s=$(mk_agent_input "$stype" "$T3/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
    assert_allow "$stype allowed unconditionally (not committer)" "$out_s"
done
rm -rf "$T3"

# ── Test 4: allow when log is missing (fail-open) ───────────────────────────
T4=$(make_project)
# No log file created; transcript references a non-existent log
FAKE_LOG="$T4/codegen/logging/nonexistent.md"
make_transcript "$T4/transcript.jsonl" "$FAKE_LOG"
out4=$(mk_agent_input "committer" "$T4/transcript.jsonl" | bash "$HOOK" 2>/dev/null || true)
assert_allow "committer allowed: no log file (fail-open)" "$out4"
rm -rf "$T4"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
