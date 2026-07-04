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

# make_wiring_stub <verdict> — creates an executable script that emits a wiring verdict.
make_wiring_stub() {
    local verdict_to_emit="$1"
    local stub_path
    stub_path=$(mktemp)
    cat >"$stub_path" <<STUB
#!/usr/bin/env bash
printf 'WIRING_VERDICT=%s\n' '$verdict_to_emit'
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

# ── Test 5: render INCONCLUSIVE chromium-launch-failed — non-fatal ───────────
T5=$(make_project)
LOG5="$T5/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG5" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T5/transcript.jsonl" "$LOG5"
STUB5=$(make_render_stub "INCONCLUSIVE:chromium-launch-failed")
out5=$(printf '%s' "$(input_for "$T5" developer-phoenix-backend false sess1 "$T5/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB5" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render chromium-launch-failed: no block" '"decision": "block"' "$out5"
assert_file_not_contains "render chromium-launch-failed: no ALL CLEAR in log (downgraded to INCONCLUSIVE)" "ALL CLEAR" "$LOG5"
assert_file_contains "render chromium-launch-failed: INCONCLUSIVE note in log" "INCONCLUSIVE" "$LOG5"
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
STUB8=$(make_render_stub "INCONCLUSIVE:chromium-launch-failed")
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

# ── Test 9: wiring FAIL — short gate blocks ───────────────────────────────────
T9=$(make_project)
LOG9="$T9/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG9" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T9/transcript.jsonl" "$LOG9"
WSTUB9=$(make_wiring_stub "FAIL:phx-click@#submit-btn")
RSTUB9=$(make_render_stub "PASS")
out9=$(printf '%s' "$(input_for "$T9" developer-phoenix-backend false sess1 "$T9/transcript.jsonl")" |
    WIRING_CHECK_CMD="$WSTUB9" RENDER_CHECK_CMD="$RSTUB9" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_contains "wiring FAIL (short): block emitted" '"decision": "block"' "$out9"
assert_file_contains "wiring FAIL (short): FAILED in log" "FAILED" "$LOG9"
assert_file_contains "wiring FAIL (short): wiring detail in log" "wiring check failed" "$LOG9"
assert_file_not_contains "wiring FAIL (short): no ALL CLEAR" "ALL CLEAR" "$LOG9"
rm -f "$WSTUB9" "$RSTUB9"
rm -rf "$T9"

# ── Test 10: wiring PASS — short gate proceeds to render ─────────────────────
T10=$(make_project)
LOG10="$T10/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG10" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T10/transcript.jsonl" "$LOG10"
WSTUB10=$(make_wiring_stub "PASS")
RSTUB10=$(make_render_stub "PASS")
out10=$(printf '%s' "$(input_for "$T10" developer-phoenix-backend false sess1 "$T10/transcript.jsonl")" |
    WIRING_CHECK_CMD="$WSTUB10" RENDER_CHECK_CMD="$RSTUB10" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "wiring PASS (short): no block" '"decision": "block"' "$out10"
assert_file_contains "wiring PASS (short): ALL CLEAR in log" "ALL CLEAR" "$LOG10"
assert_file_contains "wiring PASS (short): wiring summary in log" "wiring: PASS" "$LOG10"
rm -f "$WSTUB10" "$RSTUB10"
rm -rf "$T10"

# ── Test 11: wiring INCONCLUSIVE — short gate proceeds (fall through) ─────────
T11=$(make_project)
LOG11="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG11" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T11/transcript.jsonl" "$LOG11"
WSTUB11=$(make_wiring_stub "INCONCLUSIVE:no-heex")
RSTUB11=$(make_render_stub "PASS")
out11=$(printf '%s' "$(input_for "$T11" developer-phoenix-backend false sess1 "$T11/transcript.jsonl")" |
    WIRING_CHECK_CMD="$WSTUB11" RENDER_CHECK_CMD="$RSTUB11" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "wiring INCONCLUSIVE (short): no block" '"decision": "block"' "$out11"
assert_file_contains "wiring INCONCLUSIVE (short): ALL CLEAR in log" "ALL CLEAR" "$LOG11"
assert_file_contains "wiring INCONCLUSIVE (short): wiring INCONCLUSIVE note in log" "wiring: INCONCLUSIVE" "$LOG11"
rm -f "$WSTUB11" "$RSTUB11"
rm -rf "$T11"

# ── Test 12: long-gate wiring FAIL — blocks, no render section ───────────────
# Gate runs in long mode via gate-json block in the plan.
# Stub WIRING_CHECK_CMD to return FAIL and assert:
#   - decision: block in output
#   - log contains "FAILED" and "wiring check failed"
#   - log does NOT contain a render section (no fallthrough into render case)
T12=$(make_project)
LOG12="$T12/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
# Create a stub gate script that exits 0 and emits execution evidence
GATE12=$(mktemp)
cat >"$GATE12" <<'GATESTUB'
#!/usr/bin/env bash
printf 'make test\nALL CLEAR\n'
exit 0
GATESTUB
chmod +x "$GATE12"
cat >"$LOG12" <<MD
# Step

## Plan

**Gate**:

\`\`\`gate-json
{"command": "$GATE12", "mode": "long", "timeout": 30}
\`\`\`
MD
make_transcript "$T12/transcript.jsonl" "$LOG12"
WSTUB12=$(make_wiring_stub "FAIL:phx-click@#save")
RSTUB12=$(make_render_stub "PASS")
out12=$(printf '%s' "$(input_for "$T12" developer-phoenix-backend false sess1 "$T12/transcript.jsonl")" |
    WIRING_CHECK_CMD="$WSTUB12" RENDER_CHECK_CMD="$RSTUB12" \
        DEV_GATE_POLL_TIMEOUT_OVERRIDE=30 \
        CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_contains "long wiring FAIL: block emitted" '"decision": "block"' "$out12"
assert_file_contains "long wiring FAIL: FAILED in log" "FAILED" "$LOG12"
assert_file_contains "long wiring FAIL: wiring detail in log" "wiring check failed" "$LOG12"
assert_file_not_contains "long wiring FAIL: no render section (no fallthrough)" "render check" "$LOG12"
rm -f "$WSTUB12" "$RSTUB12" "$GATE12"
rm -rf "$T12"

# ── Test 13: RENDER_CHECK_CMD points at a nonexistent binary → INCONCLUSIVE ──
T13=$(make_project)
LOG13="$T13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG13" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T13/transcript.jsonl" "$LOG13"
out13=$(printf '%s' "$(input_for "$T13" developer-phoenix-backend false sess1 "$T13/transcript.jsonl")" |
    RENDER_CHECK_CMD="/nonexistent/render-bin" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render missing-binary: no block" '"decision": "block"' "$out13"
assert_file_not_contains "render missing-binary: no ALL CLEAR in log" "ALL CLEAR" "$LOG13"
assert_file_contains "render missing-binary: INCONCLUSIVE in log" "INCONCLUSIVE" "$LOG13"
rm -rf "$T13"

# ── Test 14: RENDER_CHECK_CMD stub exits non-zero with no verdict line → INCONCLUSIVE ──
T14=$(make_project)
LOG14="$T14/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG14" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T14/transcript.jsonl" "$LOG14"
STUB14=$(mktemp)
cat >"$STUB14" <<'STUB'
#!/usr/bin/env bash
printf 'render check crashed\n'
exit 1
STUB
chmod +x "$STUB14"
out14=$(printf '%s' "$(input_for "$T14" developer-phoenix-backend false sess1 "$T14/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB14" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render cmd-failed: no block" '"decision": "block"' "$out14"
assert_file_not_contains "render cmd-failed: no ALL CLEAR in log" "ALL CLEAR" "$LOG14"
assert_file_contains "render cmd-failed: INCONCLUSIVE in log" "INCONCLUSIVE" "$LOG14"
rm -f "$STUB14"
rm -rf "$T14"

# ── Test 15: CODEGEN_DIR unset + no override → INCONCLUSIVE (not clear) ──────
# When CODEGEN_DIR is unset and no RENDER/WIRING override is given, the default
# command expands to a path that does not exist on disk. The hook must emit
# INCONCLUSIVE (render-checker-missing or wiring-checker-missing) and NOT
# emit ALL CLEAR.
T15=$(make_project)
LOG15="$T15/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG15" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T15/transcript.jsonl" "$LOG15"
out15=$(printf '%s' "$(input_for "$T15" developer-phoenix-backend false sess1 "$T15/transcript.jsonl")" |
    env -u RENDER_CHECK_CMD -u WIRING_CHECK_CMD -u CODEGEN_DIR bash "$HOOK" 2>/dev/null || true)
assert_not_contains "CODEGEN_DIR unset: no block" '"decision": "block"' "$out15"
assert_file_not_contains "CODEGEN_DIR unset: no ALL CLEAR" "ALL CLEAR" "$LOG15"
assert_file_contains "CODEGEN_DIR unset: INCONCLUSIVE in log" "INCONCLUSIVE" "$LOG15"
rm -rf "$T15"

# ── Test 16: explicit RENDER_CHECK_CMD="" opt-out → no INCONCLUSIVE ───────────
# Setting RENDER_CHECK_CMD to empty string is deliberate opt-out (not could-not-run).
# The render step must be silently skipped; the log must show ALL CLEAR from
# the PASS wiring stub.
T16=$(make_project)
LOG16="$T16/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG16" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T16/transcript.jsonl" "$LOG16"
WSTUB16=$(make_wiring_stub "PASS")
out16=$(printf '%s' "$(input_for "$T16" developer-phoenix-backend false sess1 "$T16/transcript.jsonl")" |
    RENDER_CHECK_CMD="" WIRING_CHECK_CMD="$WSTUB16" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render opt-out: no block" '"decision": "block"' "$out16"
assert_file_contains "render opt-out: ALL CLEAR in log" "ALL CLEAR" "$LOG16"
assert_file_not_contains "render opt-out: no render INCONCLUSIVE" "render: INCONCLUSIVE" "$LOG16"
rm -f "$WSTUB16"
rm -rf "$T16"

# ── Test 17: explicit WIRING_CHECK_CMD="" opt-out → no INCONCLUSIVE ──────────
# Setting WIRING_CHECK_CMD to empty string is deliberate opt-out. The wiring
# step is silently skipped; gate proceeds to render (which passes) → ALL CLEAR.
T17=$(make_project)
LOG17="$T17/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG17" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T17/transcript.jsonl" "$LOG17"
RSTUB17=$(make_render_stub "PASS")
out17=$(printf '%s' "$(input_for "$T17" developer-phoenix-backend false sess1 "$T17/transcript.jsonl")" |
    WIRING_CHECK_CMD="" RENDER_CHECK_CMD="$RSTUB17" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "wiring opt-out: no block" '"decision": "block"' "$out17"
assert_file_contains "wiring opt-out: ALL CLEAR in log" "ALL CLEAR" "$LOG17"
assert_file_not_contains "wiring opt-out: no wiring INCONCLUSIVE" "wiring: INCONCLUSIVE" "$LOG17"
rm -f "$RSTUB17"
rm -rf "$T17"

# ── Test 18: wiring cmd exits non-zero with no verdict line → INCONCLUSIVE ───
# Today's || true swallows the crash and falls through to ALL CLEAR — this test
# was red before the rc-capture fix and is green after.
T18=$(make_project)
LOG18="$T18/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG18" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T18/transcript.jsonl" "$LOG18"
WCRASH18=$(mktemp)
cat >"$WCRASH18" <<'STUB'
#!/usr/bin/env bash
printf 'wiring crashed\n'
exit 1
STUB
chmod +x "$WCRASH18"
RSTUB18=$(make_render_stub "PASS")
out18=$(printf '%s' "$(input_for "$T18" developer-phoenix-backend false sess1 "$T18/transcript.jsonl")" |
    WIRING_CHECK_CMD="$WCRASH18" RENDER_CHECK_CMD="$RSTUB18" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
# Wiring INCONCLUSIVE is fail-open: no block, ALL CLEAR still emitted (with an INCONCLUSIVE note).
# Before the rc-capture fix, the crash was fully masked (|| true) → no INCONCLUSIVE note at all.
# After fix: INCONCLUSIVE note appears — crash is no longer silently swallowed.
assert_not_contains "wiring crash: no block" '"decision": "block"' "$out18"
assert_file_contains "wiring crash: INCONCLUSIVE note in log" "wiring: INCONCLUSIVE" "$LOG18"
rm -f "$WCRASH18" "$RSTUB18"
rm -rf "$T18"

# ── Test 19: Witness present — parseable ExUnit location in block envelope ────
TW=$(make_project)
LOGW="$TW/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOGW" <<'MD'
# Step

## Plan

**Gate**: `printf '  1) test boom\n     test/foo_test.exs:42\n** (RuntimeError) boom\n'; exit 1`
MD
make_transcript "$TW/transcript.jsonl" "$LOGW"
outw=$(printf '%s' "$(input_for "$TW" developer-phoenix-backend false sess1 "$TW/transcript.jsonl")" |
    CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_contains "witness parseable: block carries Witness prefix" "Witness: test/foo_test.exs:42" "$outw"
assert_contains "witness parseable: tail still present in block" "Tail:" "$outw"
assert_file_contains "witness parseable: gate-result.json has witness field" "test/foo_test.exs:42" \
    "$TW/codegen/gate-pending/gate-result.json"
rm -rf "$TW"

# ── Test 20: Witness absent — unparseable log, no Witness prefix in block ─────
TU=$(make_project)
LOGU="$TU/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOGU" <<'MD'
# Step

## Plan

**Gate**: `printf 'opaque noise no location\n'; exit 1`
MD
make_transcript "$TU/transcript.jsonl" "$LOGU"
outu=$(printf '%s' "$(input_for "$TU" developer-phoenix-backend false sess1 "$TU/transcript.jsonl")" |
    CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "witness unparseable: no Witness prefix" "Witness:" "$outu"
assert_contains "witness unparseable: tail still present" "Tail:" "$outu"
rm -rf "$TU"

# ── Test 21: flat-layout — sibling render-check.js + wiring-check.js PASS ─────
# Proves the hook resolves render-check.js and wiring-check.js sibling-relative
# (BASH_SOURCE[0]) without CODEGEN_DIR. Copy hook + all lib/* into a temp dir so
# <tmp>/phoenix-dev-gate.sh and <tmp>/lib/... are siblings; plant PASS stubs at
# <tmp>/lib/render-check.js and <tmp>/lib/wiring-check.js.
T21_FLAT=$(mktemp -d)
mkdir -p "$T21_FLAT/lib"
cp "$HOOK" "$T21_FLAT/"
cp "$SCRIPT_DIR"/lib/*.sh "$T21_FLAT/lib/"
# Plant PASS stubs as sibling .js files
cat >"$T21_FLAT/lib/render-check.js" <<'JS'
process.stdout.write('RENDER_VERDICT=PASS\n');
JS
cat >"$T21_FLAT/lib/wiring-check.js" <<'JS'
process.stdout.write('WIRING_VERDICT=PASS\n');
JS
T21=$(make_project)
LOG21="$T21/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG21" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T21/transcript.jsonl" "$LOG21"
out21=$(printf '%s' "$(input_for "$T21" developer-phoenix-backend false sess1 "$T21/transcript.jsonl")" |
    env -u RENDER_CHECK_CMD -u WIRING_CHECK_CMD -u CODEGEN_DIR bash "$T21_FLAT/phoenix-dev-gate.sh" 2>/dev/null || true)
# Sibling stubs both emit PASS — expect no block + ALL CLEAR in log.
assert_not_contains "flat-layout sibling PASS stubs: no block" '"decision": "block"' "$out21"
assert_file_contains "flat-layout sibling PASS stubs: ALL CLEAR in log" "ALL CLEAR" "$LOG21"
rm -rf "$T21_FLAT" "$T21"

# ── Test 22: flat-layout — sibling render-check.js ABSENT → INCONCLUSIVE ──────
# When render-check.js is missing from the sibling lib/ dir, the preflight check
# must emit INCONCLUSIVE (render-checker-missing) and NOT emit ALL CLEAR.
T22_FLAT=$(mktemp -d)
mkdir -p "$T22_FLAT/lib"
cp "$HOOK" "$T22_FLAT/"
cp "$SCRIPT_DIR"/lib/*.sh "$T22_FLAT/lib/"
# Plant wiring-check.js stub but NOT render-check.js
cat >"$T22_FLAT/lib/wiring-check.js" <<'JS'
process.stdout.write('WIRING_VERDICT=PASS\n');
JS
T22=$(make_project)
LOG22="$T22/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG22" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T22/transcript.jsonl" "$LOG22"
out22=$(printf '%s' "$(input_for "$T22" developer-phoenix-backend false sess1 "$T22/transcript.jsonl")" |
    env -u RENDER_CHECK_CMD -u WIRING_CHECK_CMD -u CODEGEN_DIR bash "$T22_FLAT/phoenix-dev-gate.sh" 2>/dev/null || true)
# render-checker-missing → INCONCLUSIVE, non-fatal, no ALL CLEAR.
assert_not_contains "flat-layout absent render-check.js: no block" '"decision": "block"' "$out22"
assert_file_not_contains "flat-layout absent render-check.js: no ALL CLEAR" "ALL CLEAR" "$LOG22"
assert_file_contains "flat-layout absent render-check.js: INCONCLUSIVE in log" "INCONCLUSIVE" "$LOG22"
rm -rf "$T22_FLAT" "$T22"

# ── Test 23: render-check cmd exits nonzero with stderr → INCONCLUSIVE carries marker ──
# A stub that emits a stderr marker and exits 1 (no RENDER_VERDICT= line).
# The INCONCLUSIVE verdict surfaced in the log must contain the marker.
T23=$(make_project)
LOG23="$T23/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG23" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T23/transcript.jsonl" "$LOG23"
RSTUB23=$(mktemp)
cat >"$RSTUB23" <<'STUB'
#!/usr/bin/env bash
printf '__RENDER_STDERR_MARKER__\n' >&2
exit 1
STUB
chmod +x "$RSTUB23"
WSTUB23=$(make_wiring_stub "PASS")
out23=$(printf '%s' "$(input_for "$T23" developer-phoenix-backend false sess1 "$T23/transcript.jsonl")" |
    RENDER_CHECK_CMD="$RSTUB23" WIRING_CHECK_CMD="$WSTUB23" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "render-check stderr: no block" '"decision": "block"' "$out23"
assert_file_contains "render-check stderr: INCONCLUSIVE in log" "INCONCLUSIVE" "$LOG23"
assert_file_contains "render-check stderr: marker in INCONCLUSIVE detail" "__RENDER_STDERR_MARKER__" "$LOG23"
rm -f "$RSTUB23" "$WSTUB23"
rm -rf "$T23"

# ── Test 24: wiring-check cmd exits nonzero with stderr → INCONCLUSIVE carries marker ──
# A stub that emits a stderr marker and exits 1 (no WIRING_VERDICT= line).
# The INCONCLUSIVE verdict surfaced in the log must contain the marker.
T24=$(make_project)
LOG24="$T24/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG24" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T24/transcript.jsonl" "$LOG24"
WCRASH24=$(mktemp)
cat >"$WCRASH24" <<'STUB'
#!/usr/bin/env bash
printf '__WIRING_STDERR_MARKER__\n' >&2
exit 1
STUB
chmod +x "$WCRASH24"
RSTUB24=$(make_render_stub "PASS")
out24=$(printf '%s' "$(input_for "$T24" developer-phoenix-backend false sess1 "$T24/transcript.jsonl")" |
    WIRING_CHECK_CMD="$WCRASH24" RENDER_CHECK_CMD="$RSTUB24" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "wiring-check stderr: no block" '"decision": "block"' "$out24"
assert_file_contains "wiring-check stderr: INCONCLUSIVE in log" "wiring: INCONCLUSIVE" "$LOG24"
assert_file_contains "wiring-check stderr: marker in INCONCLUSIVE detail" "__WIRING_STDERR_MARKER__" "$LOG24"
rm -f "$WCRASH24" "$RSTUB24"
rm -rf "$T24"

# ── Test 25: codegen self-build sentinel — render/wiring skipped, ALL CLEAR ───
# When registry.yaml sentinel exists at project_dir/shared/enforcement/registry.yaml,
# both render and wiring checks must be bypassed even when stubs would emit INCONCLUSIVE.
T25=$(make_project)
mkdir -p "$T25/shared/enforcement"
touch "$T25/shared/enforcement/registry.yaml"
LOG25="$T25/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG25" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T25/transcript.jsonl" "$LOG25"
STUB25=$(make_render_stub "INCONCLUSIVE:server-unready")
out25=$(printf '%s' "$(input_for "$T25" developer-phoenix-backend false sess1 "$T25/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB25" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "codegen sentinel: no block" '"decision": "block"' "$out25"
assert_file_not_contains "codegen sentinel: no INCONCLUSIVE in log" "INCONCLUSIVE" "$LOG25"
assert_file_contains "codegen sentinel: ALL CLEAR in log" "ALL CLEAR" "$LOG25"
rm -f "$STUB25"
rm -rf "$T25"

# ── Test 26: sole-writer invariant — verdict routes via codegen-log, no raw >> ──
# The hook source itself must contain zero raw `>>"$log_file"`/`>> "$log_file"`
# writes (Phase 5: all such sites replaced by `codegen-log verdict` calls).
# This is a static grep of the hook SOURCE, not a runtime behavior assertion —
# it directly proves the sole-writer invariant the pitch requires.
raw_write_count=$(grep -cE '>>[[:space:]]*"?\$log_file"?' "$HOOK" || true)
assert_eq_num() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}
assert_eq_num "sole-writer: zero raw >>\"\$log_file\" writes remain in phoenix-dev-gate.sh" "0" "${raw_write_count:-0}"

# ── Test 27: verdict output byte-shape unchanged — ALL CLEAR path ────────────
# Confirms the "## dev-gate Section" block routed through codegen-log verdict
# carries the exact same field labels/order as the pre-Phase-5 raw-write shape:
# Gate:/Ran:/**Rules loaded**:/**Commands executed**: table/**Result**:.
T26=$(make_project)
LOG26="$T26/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step1.md"
cat >"$LOG26" <<'MD'
# Step

## Plan

**Gate**: `true`
MD
make_transcript "$T26/transcript.jsonl" "$LOG26"
STUB26=$(make_render_stub "PASS")
WSTUB26=$(make_wiring_stub "PASS")
out26=$(printf '%s' "$(input_for "$T26" developer-phoenix-backend false sess1 "$T26/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB26" WIRING_CHECK_CMD="$WSTUB26" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
assert_file_contains "verdict shape: dev-gate Section header present" "## dev-gate Section" "$LOG26"
assert_file_contains "verdict shape: Gate: line present" "Gate: true" "$LOG26"
assert_file_contains "verdict shape: Ran: line present" "Ran: true" "$LOG26"
assert_file_contains "verdict shape: Rules loaded line present" "**Rules loaded**: deterministic hook (dev-gate.sh) — no rules loaded" "$LOG26"
assert_file_contains "verdict shape: Commands executed table header present" "**Commands executed**:" "$LOG26"
assert_file_contains "verdict shape: table column header row present" "| Time (HH:MM:SS UTC) | Command | Exit | Notes |" "$LOG26"
assert_file_contains "verdict shape: Result line present" "**Result**: ALL CLEAR ✅" "$LOG26"
assert_file_contains "verdict shape: wiring detail folded into section body" "wiring: PASS" "$LOG26"
assert_file_contains "verdict shape: render detail folded into section body" "render: DOM non-empty" "$LOG26"
rm -f "$STUB26" "$WSTUB26"
rm -rf "$T26"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
