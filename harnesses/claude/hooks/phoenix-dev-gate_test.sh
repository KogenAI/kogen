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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
