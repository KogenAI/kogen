#!/usr/bin/env bash
# phoenix-dev-gate_test.sh — render-check integration tests for phoenix-dev-gate.sh.
#
# Tests the render-verification step added to the short-gate and long-gate
# success paths. Uses a RENDER_CHECK_CMD stub to control the verdict without
# needing a real browser or running Phoenix.
#
# Complements phoenix-dev-gate-short_test.sh and phoenix-dev-gate-long_test.sh;
# focuses only on render-check behaviour.

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

assert_file_not_contains() {
    local desc="$1"
    local needle="$2"
    local file="$3"
    if [ -f "$file" ] && grep -qF "$needle" "$file"; then
        printf 'FAIL: %s\n  unexpected: %s\n  file: %s\n' "$desc" "$needle" "$file"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
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

# make_render_stub <verdict> — creates an executable script that emits the verdict.
make_render_stub() {
    local verdict_to_emit="$1"
    local stub_path
    stub_path=$(mktemp)
    cat >"$stub_path" <<STUB
#!/usr/bin/env bash
printf 'RENDER_VERDICT=%s\n' '$verdict_to_emit'
STUB
    chmod +x "$stub_path"
    printf '%s' "$stub_path"
}

# ── Test 1: render PASS — short gate success + render PASS → ALL CLEAR ───────
T1=$(make_project)
LOG1="$T1/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG1" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T1/transcript.jsonl" "$LOG1"
STUB1=$(make_render_stub "PASS")
out1=$(printf '%s' "$(input_for "$T1" developer-phoenix-backend false sess1 "$T1/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB1" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render PASS: short gate no block" '"decision": "block"' "$out1"
assert_file_contains "render PASS: ALL CLEAR in log" "ALL CLEAR" "$LOG1"
assert_file_contains "render PASS: render summary in log" "DOM non-empty" "$LOG1"
rm -f "$STUB1"
rm -rf "$T1"

# ── Test 2: render FAIL empty-dom — short gate blocks ───────────────────────
T2=$(make_project)
LOG2="$T2/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG2" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T2/transcript.jsonl" "$LOG2"
STUB2=$(make_render_stub "FAIL:empty-dom")
out2=$(printf '%s' "$(input_for "$T2" developer-phoenix-backend false sess1 "$T2/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB2" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_contains "render FAIL empty-dom: block emitted" '"decision": "block"' "$out2"
assert_file_contains "render FAIL empty-dom: FAILED in log" "FAILED" "$LOG2"
assert_file_not_contains "render FAIL empty-dom: no ALL CLEAR" "ALL CLEAR" "$LOG2"
rm -f "$STUB2"
rm -rf "$T2"

# ── Test 3: render FAIL unstyled — short gate blocks ────────────────────────
T3=$(make_project)
LOG3="$T3/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG3" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T3/transcript.jsonl" "$LOG3"
STUB3=$(make_render_stub "FAIL:unstyled")
out3=$(printf '%s' "$(input_for "$T3" developer-phoenix-backend false sess1 "$T3/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB3" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_contains "render FAIL unstyled: block emitted" '"decision": "block"' "$out3"
assert_file_contains "render FAIL unstyled: FAILED in log" "FAILED" "$LOG3"
rm -f "$STUB3"
rm -rf "$T3"

# ── Test 4: render FAIL js-error — short gate blocks ────────────────────────
T4=$(make_project)
LOG4="$T4/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG4" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T4/transcript.jsonl" "$LOG4"
STUB4=$(make_render_stub "FAIL:js-error:ReferenceError: x is not defined")
out4=$(printf '%s' "$(input_for "$T4" developer-phoenix-backend false sess1 "$T4/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB4" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_contains "render FAIL js-error: block emitted" '"decision": "block"' "$out4"
assert_file_contains "render FAIL js-error: FAILED in log" "FAILED" "$LOG4"
rm -f "$STUB4"
rm -rf "$T4"

# ── Test 5: render INCONCLUSIVE browser-not-installed — non-fatal ────────────
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG5" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T5/transcript.jsonl" "$LOG5"
STUB5=$(make_render_stub "INCONCLUSIVE:browser-not-installed")
out5=$(printf '%s' "$(input_for "$T5" developer-phoenix-backend false sess1 "$T5/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB5" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render INCONCLUSIVE: no block" '"decision": "block"' "$out5"
assert_file_not_contains "render INCONCLUSIVE: no ALL CLEAR in log (downgraded to INCONCLUSIVE)" "ALL CLEAR" "$LOG5"
assert_file_contains "render INCONCLUSIVE: INCONCLUSIVE note in log" "INCONCLUSIVE" "$LOG5"
rm -f "$STUB5"
rm -rf "$T5"

# ── Test 6: render INCONCLUSIVE server-unready — non-fatal ───────────────────
T6=$(make_project)
LOG6="$T6/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG6" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T6/transcript.jsonl" "$LOG6"
STUB6=$(make_render_stub "INCONCLUSIVE:server-unready")
out6=$(printf '%s' "$(input_for "$T6" developer-phoenix-backend false sess1 "$T6/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB6" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render server-unready: no block" '"decision": "block"' "$out6"
assert_file_not_contains "render server-unready: no ALL CLEAR in log (downgraded to INCONCLUSIVE)" "ALL CLEAR" "$LOG6"
assert_file_contains "render server-unready: INCONCLUSIVE note in log" "INCONCLUSIVE" "$LOG6"
rm -f "$STUB6"
rm -rf "$T6"

# ── Test 7: GATED/clear stamp written on short-gate ALL CLEAR ────────────────
T7=$(make_project)
LOG7="$T7/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG7" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T7/transcript.jsonl" "$LOG7"
STUB7=$(make_render_stub "PASS")
out7=$(printf '%s' "$(input_for "$T7" developer-phoenix-backend false sess1 "$T7/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB7" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
cs_state7=""
cs_file7="$T7/codegen/gate-pending/cycle-state.json"
if [ -f "$cs_file7" ]; then
    cs_state7=$(jq -r '.state // ""' "$cs_file7" 2>/dev/null || printf '')
fi
cs_verdict7=""
if [ -f "$cs_file7" ]; then
    cs_verdict7=$(jq -r '.verdict // ""' "$cs_file7" 2>/dev/null || printf '')
fi
if [ "$cs_state7" = "GATED" ] && [ "$cs_verdict7" = "clear" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: short-gate ALL CLEAR stamps GATED/clear in cycle-state.json\n'
    pass=$((pass + 1))
else
    printf 'FAIL: short-gate ALL CLEAR — expected state=GATED verdict=clear, got state=%s verdict=%s\n' \
        "$cs_state7" "$cs_verdict7"
    fail=$((fail + 1))
fi
rm -f "$STUB7"
rm -rf "$T7"

# ── Test 8: GATED/inconclusive stamp written on short-gate INCONCLUSIVE ──────
T8=$(make_project)
LOG8="$T8/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG8" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T8/transcript.jsonl" "$LOG8"
STUB8=$(make_render_stub "INCONCLUSIVE:browser-not-installed")
out8=$(printf '%s' "$(input_for "$T8" developer-phoenix-backend false sess1 "$T8/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB8" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
cs_state8=""
cs_verdict8=""
cs_file8="$T8/codegen/gate-pending/cycle-state.json"
if [ -f "$cs_file8" ]; then
    cs_state8=$(jq -r '.state // ""' "$cs_file8" 2>/dev/null || printf '')
    cs_verdict8=$(jq -r '.verdict // ""' "$cs_file8" 2>/dev/null || printf '')
fi
if [ "$cs_state8" = "GATED" ] && [ "$cs_verdict8" = "inconclusive" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: short-gate INCONCLUSIVE stamps GATED/inconclusive in cycle-state.json\n'
    pass=$((pass + 1))
else
    printf 'FAIL: short-gate INCONCLUSIVE — expected state=GATED verdict=inconclusive, got state=%s verdict=%s\n' \
        "$cs_state8" "$cs_verdict8"
    fail=$((fail + 1))
fi
rm -f "$STUB8"
rm -rf "$T8"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
