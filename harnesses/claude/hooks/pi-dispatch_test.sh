#!/usr/bin/env bash
# pi-dispatch_test.sh — unit tests for harnesses/pi/call-dispatch.sh
#
# Uses a PATH-override stub 'pi' that emits agent_end JSONL fixtures,
# so no real pi/LLM calls are made.
#
# Cases:
#   (1) success no-schema: text, no trailing "?" → status=success
#   (2) question-mark reply no-schema: text ends "?" → status=success
#   (3) schema set + valid JSON → status=success, result.value is object
#   (4) schema set + reply ends "?" → status not clarifying_question (heuristic gone in both directions)
#   (5) schema-validate FAIL: JSON omits required field → status=failed, reason~schema
#   (6) pi exits non-zero + no agent_end → status=failed, reason~"pi exited non-zero"
#   (7) pi exits 0 + no agent_end → status=failed, reason~"no agent_end"
#   (8) schema set + non-JSON reply → status=failed, reason~"non-JSON reply"

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SCRIPT="$(cd "$HOOKS_DIR/../../pi" && pwd)/call-dispatch.sh"
FIXTURES_DIR="$HOOKS_DIR/fixtures"

# shellcheck source=/dev/null
source "$HOOKS_DIR/../../shared/test-stub-lib.sh"

pass=0
fail=0

assert_jq() {
    local desc="$1"
    local json="$2"
    local jq_expr="$3"
    local expected="$4"
    local actual
    actual="$(printf '%s' "$json" | jq -r "$jq_expr" 2>/dev/null || printf 'JQ_ERROR')"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — jq %q expected %q, got %q\n  json: %s\n' "$desc" "$jq_expr" "$expected" "$actual" "${json:0:300}"
        fail=$((fail + 1))
    fi
}

assert_jq_truthy() {
    local desc="$1"
    local json="$2"
    local jq_expr="$3"
    local actual
    actual="$(printf '%s' "$json" | jq -r "$jq_expr" 2>/dev/null || printf 'JQ_ERROR')"
    if [[ "$actual" == "true" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — jq %q expected true, got %q\n  json: %s\n' "$desc" "$jq_expr" "$actual" "${json:0:300}"
        fail=$((fail + 1))
    fi
}

assert_jq_not_equal() {
    local desc="$1"
    local json="$2"
    local jq_expr="$3"
    local unexpected="$4"
    local actual
    actual="$(printf '%s' "$json" | jq -r "$jq_expr" 2>/dev/null || printf 'JQ_ERROR')"
    if [[ "$actual" != "$unexpected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — jq %q must not equal %q, got %q\n  json: %s\n' "$desc" "$jq_expr" "$unexpected" "$actual" "${json:0:300}"
        fail=$((fail + 1))
    fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

# Create a PATH-override stub 'pi' that emits the fixture file and exits 0
STUB_DIR="$BASE_TMP/stub_bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/pi.body" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub pi: ignore all args, emit fixture JSONL to stdout, exit ${STUB_EXIT:-0}
cat "$FIXTURE_PATH"
exit "${STUB_EXIT:-0}"
STUB_EOF
link_stub_path "$STUB_DIR/pi"

export PATH="$STUB_DIR:$PATH"

# Common env (schema-free by default; override per case)
BASE_ENV=(
    CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    CODEGEN_CALL_MODEL="fake-model"
    CODEGEN_CALL_EFFORT="low"
    CODEGEN_CALL_PROMPT="Classify this message."
)

run_dispatch() {
    local fixture="$1"
    shift
    local env_vars=()
    if [[ "$#" -gt 0 ]]; then
        env_vars=("$@")
    fi
    (
        for v in "${BASE_ENV[@]}"; do export "$v"; done
        unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
        unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
        unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
        unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
        if [[ "${#env_vars[@]}" -gt 0 ]]; then
            for v in "${env_vars[@]}"; do export "$v"; done
        fi
        FIXTURE_PATH="$fixture"
        export FIXTURE_PATH
        bash "$DISPATCH_SCRIPT" 2>/dev/null
    ) || true
}

# ── Case (1): success no-schema — plain text, no trailing "?" ─────────────────
ENVELOPE1="$(run_dispatch "$FIXTURES_DIR/pi_success_text.jsonl")"

assert_jq \
    "(1) success no-schema: result.status" \
    "$ENVELOPE1" \
    ".result.status" \
    "success"

assert_jq \
    "(1) success no-schema: harness=pi" \
    "$ENVELOPE1" \
    ".harness" \
    "pi"

# ── Case (2): question-mark reply no-schema — text ends "?" → success ─────────
ENVELOPE2="$(run_dispatch "$FIXTURES_DIR/pi_question_mark_reply.jsonl")"

assert_jq \
    "(2) question-mark reply no-schema: result.status" \
    "$ENVELOPE2" \
    ".result.status" \
    "success"

assert_jq_truthy \
    "(2) question-mark reply no-schema: result.value ends ?" \
    "$ENVELOPE2" \
    '(.result.value // "") | test("\\?[[:space:]]*$")'

# ── Case (3): schema set + valid JSON → success, value is object ──────────────
SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
ENVELOPE3="$(run_dispatch "$FIXTURES_DIR/pi_schema_valid.jsonl" "CODEGEN_CALL_JSON_SCHEMA=$SCHEMA")"

assert_jq \
    "(3) schema+valid JSON: result.status" \
    "$ENVELOPE3" \
    ".result.status" \
    "success"

assert_jq_truthy \
    "(3) schema+valid JSON: result.value is object" \
    "$ENVELOPE3" \
    '(.result.value | type) == "object"'

# ── Case (4): schema set + reply ends "?" → status not clarifying_question ────
ENVELOPE4="$(run_dispatch "$FIXTURES_DIR/pi_schema_cq_asymmetry.jsonl" "CODEGEN_CALL_JSON_SCHEMA=$SCHEMA")"

assert_jq_not_equal \
    "(4) schema+question-mark reply: status must not be clarifying_question" \
    "$ENVELOPE4" \
    ".result.status" \
    "clarifying_question"

# ── Case (5): schema-validate FAIL — JSON omits required field ────────────────
ENVELOPE5="$(run_dispatch "$FIXTURES_DIR/pi_schema_validate_fail.jsonl" "CODEGEN_CALL_JSON_SCHEMA=$SCHEMA")"

assert_jq \
    "(5) schema-validate FAIL: result.status == failed" \
    "$ENVELOPE5" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(5) schema-validate FAIL: reason contains 'schema'" \
    "$ENVELOPE5" \
    '(.result.reason // "") | test("schema")'

# ── Case (6): pi exits non-zero + no agent_end → failed, reason~"pi exited non-zero" ─
ENVELOPE6="$(run_dispatch "$FIXTURES_DIR/pi_no_agent_end_nonzero.jsonl" "STUB_EXIT=3")"

assert_jq \
    "(6) pi non-zero exit: result.status == failed" \
    "$ENVELOPE6" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(6) pi non-zero exit: reason contains 'pi exited non-zero'" \
    "$ENVELOPE6" \
    '(.result.reason // "") | test("pi exited non-zero")'

assert_jq \
    "(6) pi non-zero exit: harness=pi" \
    "$ENVELOPE6" \
    ".harness" \
    "pi"

# ── Case (7): pi exits 0 + no agent_end → failed, reason~"no agent_end" ──────
ENVELOPE7="$(run_dispatch "$FIXTURES_DIR/pi_no_agent_end.jsonl")"

assert_jq \
    "(7) exit-0 no agent_end: result.status == failed" \
    "$ENVELOPE7" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(7) exit-0 no agent_end: reason contains 'no agent_end'" \
    "$ENVELOPE7" \
    '(.result.reason // "") | test("no agent_end")'

assert_jq \
    "(7) exit-0 no agent_end: harness=pi" \
    "$ENVELOPE7" \
    ".harness" \
    "pi"

# ── Case (8): schema set + non-JSON reply → failed, reason~"non-JSON reply" ──
ENVELOPE8="$(run_dispatch "$FIXTURES_DIR/pi_schema_nonjson_reply.jsonl" "CODEGEN_CALL_JSON_SCHEMA=$SCHEMA")"

assert_jq \
    "(8) non-JSON under schema: result.status == failed" \
    "$ENVELOPE8" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(8) non-JSON under schema: reason contains 'non-JSON reply'" \
    "$ENVELOPE8" \
    '(.result.reason // "") | test("non-JSON reply")'

assert_jq \
    "(8) non-JSON under schema: harness=pi" \
    "$ENVELOPE8" \
    ".harness" \
    "pi"

# ── Watchdog: hang-after-emit salvage + mid-stream stall (CODEGEN_LOOP=1) ────
# Mirrors harnesses/claude/hooks/call-dispatch_test.sh's watchdog cases.
WATCHDOG_STUB_DIR="$BASE_TMP/watchdog_stub_bin"
mkdir -p "$WATCHDOG_STUB_DIR"
cat >"$WATCHDOG_STUB_DIR/pi.body" <<'WDSTUB'
#!/usr/bin/env bash
# Stub pi: emit fixture (agent_end event present), then hang forever.
cat "$FIXTURE_PATH"
sleep 3600
WDSTUB
link_stub_path "$WATCHDOG_STUB_DIR/pi"

WATCHDOG_STALL_STUB_DIR="$BASE_TMP/watchdog_stall_stub_bin"
mkdir -p "$WATCHDOG_STALL_STUB_DIR"
cat >"$WATCHDOG_STALL_STUB_DIR/pi.body" <<'WDSTALLSTUB'
#!/usr/bin/env bash
# Stub pi: no output, hang forever.
sleep 3600
WDSTALLSTUB
link_stub_path "$WATCHDOG_STALL_STUB_DIR/pi"

# (x) Hang-after-emit: agent_end event present, process never exits →
# watchdog kills after RESULT_GRACE_SECS, salvages as success.
WD_X_EXIT=0
WD_X_START=$(date +%s)
(
    export PATH="$WATCHDOG_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    export FIXTURE_PATH="$FIXTURES_DIR/pi_success_text.jsonl"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=2
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_POLL_SECS=0.5
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x_stderr.log"
) >"$BASE_TMP/wd_x_envelope.json" || WD_X_EXIT=$?
WD_X_ELAPSED=$(($(date +%s) - WD_X_START))

if [[ "$WD_X_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x) watchdog hang-after-emit exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x) watchdog hang-after-emit exits 0 — got %d\n  stderr: %s\n' "$WD_X_EXIT" "$(cat "$BASE_TMP/wd_x_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

WD_X_ENVELOPE="$(cat "$BASE_TMP/wd_x_envelope.json")"
assert_jq \
    "(x) watchdog hang-after-emit: salvaged as success" \
    "$WD_X_ENVELOPE" \
    ".result.status" \
    "success"

if grep -qF "watchdog killing pi" "$BASE_TMP/wd_x_stderr.log" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x) stderr names watchdog kill\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x) stderr missing watchdog kill message: %s\n' "$(cat "$BASE_TMP/wd_x_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

if [[ "$WD_X_ELAPSED" -lt 60 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x) watchdog recovers well under idle cap (%ds)\n' "$WD_X_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (x) watchdog took too long to recover (%ds)\n' "$WD_X_ELAPSED"
    fail=$((fail + 1))
fi

# (y) Mid-stream stall: no output at all → watchdog idle-caps, emits failed
# envelope with retryable "Stream idle timeout" reason, exits 0 (not 1).
WD_Y_EXIT=0
(
    export PATH="$WATCHDOG_STALL_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    export FIXTURE_PATH="$FIXTURES_DIR/pi_success_text.jsonl"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=2
    export CODEGEN_CALL_POLL_SECS=0.5
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_y_stderr.log"
) >"$BASE_TMP/wd_y_envelope.json" || WD_Y_EXIT=$?

if [[ "$WD_Y_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (y) watchdog mid-stream stall exits 0 (not 1)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (y) watchdog mid-stream stall exits 0 — got %d\n' "$WD_Y_EXIT"
    fail=$((fail + 1))
fi

WD_Y_ENVELOPE="$(cat "$BASE_TMP/wd_y_envelope.json")"
assert_jq \
    "(y) watchdog mid-stream stall: result.status == failed" \
    "$WD_Y_ENVELOPE" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(y) watchdog mid-stream stall: reason contains retryable taxonomy token" \
    "$WD_Y_ENVELOPE" \
    '(.result.reason // "") | test("Stream idle timeout")'

if grep -qF "watchdog killing pi" "$BASE_TMP/wd_y_stderr.log" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (y) stderr names watchdog kill\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (y) stderr missing watchdog kill message: %s\n' "$(cat "$BASE_TMP/wd_y_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

# (z) Loop-gate off (no CODEGEN_LOOP): watchdog never engages — one-shot
# platform codegen-call behavior stays byte-identical. Uses the normal
# short-lived stub, not the hanging one.
WD_Z_EXIT=0
(
    export PATH="$STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    unset CODEGEN_LOOP 2>/dev/null || true
    export FIXTURE_PATH="$FIXTURES_DIR/pi_success_text.jsonl"
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_z_stderr.log"
) >"$BASE_TMP/wd_z_envelope.json" || WD_Z_EXIT=$?

if [[ "$WD_Z_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (z) loop-gate off: dispatch exits 0 normally\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (z) loop-gate off: dispatch exits 0 — got %d\n' "$WD_Z_EXIT"
    fail=$((fail + 1))
fi

assert_jq \
    "(z) loop-gate off: result.status == success (unaffected by watchdog)" \
    "$(cat "$BASE_TMP/wd_z_envelope.json")" \
    ".result.status" \
    "success"

if grep -qF "watchdog killing pi" "$BASE_TMP/wd_z_stderr.log" 2>/dev/null; then
    printf 'FAIL: (z) loop-gate off: watchdog unexpectedly engaged\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (z) loop-gate off: watchdog never engages\n'
    pass=$((pass + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
