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
        unset CODEGEN_LOOP 2>/dev/null || true
        if [[ "${#env_vars[@]}" -gt 0 ]]; then
            for v in "${env_vars[@]}"; do export "$v"; done
        fi
        FIXTURE_PATH="$fixture"
        export FIXTURE_PATH
        bash "$DISPATCH_SCRIPT" 2>/dev/null
    ) || true
}

# ── Case (1): success no-schema — plain text, no trailing "?" ─────────────────
ARGV1="$(
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export CODEGEN_CALL_PRINT_ARGV=1
    bash "$DISPATCH_SCRIPT"
)"
if printf '%s\n' "$ARGV1" | awk 'previous == "--thinking" && $0 == "low" { found = 1 } { previous = $0 } END { exit !found }'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (1) managed Pi preserves configured effort\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (1) managed Pi did not forward configured effort: %s\n' "$ARGV1"
    fail=$((fail + 1))
fi

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

# This stub leaves a descendant holding inherited stream FDs. The dispatcher
# must terminate its entire process group, then drain the filter without delay.
WATCHDOG_DRAIN_STUB_DIR="$BASE_TMP/watchdog_drain_stub_bin"
mkdir -p "$WATCHDOG_DRAIN_STUB_DIR"
cat >"$WATCHDOG_DRAIN_STUB_DIR/pi.body" <<'WDDRAINSTUB'
#!/usr/bin/env bash
cat "$FIXTURE_PATH"
sleep 3600 &
printf '%s' "$!" >"$PI_DESCENDANT_PID_PATH"
wait
WDDRAINSTUB
link_stub_path "$WATCHDOG_DRAIN_STUB_DIR/pi"

WATCHDOG_STALL_STUB_DIR="$BASE_TMP/watchdog_stall_stub_bin"
mkdir -p "$WATCHDOG_STALL_STUB_DIR"
cat >"$WATCHDOG_STALL_STUB_DIR/pi.body" <<'WDSTALLSTUB'
#!/usr/bin/env bash
# Stub Pi: emit no output, then replace itself with a childless hang; dead-stream must fire.
[[ -z "${PI_STUB_PID_PATH:-}" ]] || printf '%s' "$$" >"$PI_STUB_PID_PATH"
exec perl -e 'select undef, undef, undef, 3600'
WDSTALLSTUB
link_stub_path "$WATCHDOG_STALL_STUB_DIR/pi"

# A no-output Pi fixture with one live child, representing a long-running tool.
# The short stream-idle cap must not fire while this child remains alive.
WATCHDOG_TOOL_STUB_DIR="$BASE_TMP/watchdog_tool_stub_bin"
mkdir -p "$WATCHDOG_TOOL_STUB_DIR"
cat >"$WATCHDOG_TOOL_STUB_DIR/pi.body" <<'WDTOOLSTUB'
#!/usr/bin/env bash
sleep 3600
WDTOOLSTUB
link_stub_path "$WATCHDOG_TOOL_STUB_DIR/pi"

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

# (x1) terminal agent_end followed by threshold compaction is complete work,
# not a generic hang: salvage immediately instead of waiting result grace.
COMPACTION_AFTER_RESULT="$BASE_TMP/compaction_after_result.jsonl"
printf '%s\n' \
    '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"done"}]}]}' \
    '{"type":"compaction_start","reason":"threshold"}' \
    >"$COMPACTION_AFTER_RESULT"
WD_X1_EXIT=0
WD_X1_START=$(date +%s)
(
    export PATH="$WATCHDOG_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export FIXTURE_PATH="$COMPACTION_AFTER_RESULT"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=10
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x1_stderr.log"
) >"$BASE_TMP/wd_x1_envelope.json" || WD_X1_EXIT=$?
WD_X1_ELAPSED=$(($(date +%s) - WD_X1_START))

if [[ "$WD_X1_EXIT" -eq 0 ]] && [[ "$WD_X1_ELAPSED" -lt 5 ]] &&
    grep -qF "canceled post-result Pi compaction; terminal result salvaged" "$BASE_TMP/wd_x1_stderr.log"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x1) terminal threshold compaction salvages immediately\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x1) terminal threshold compaction was not immediate: exit=%s elapsed=%ss stderr=%s\n' \
        "$WD_X1_EXIT" "$WD_X1_ELAPSED" "$(<"$BASE_TMP/wd_x1_stderr.log")"
    fail=$((fail + 1))
fi

WD_X1_ENVELOPE="$(<"$BASE_TMP/wd_x1_envelope.json")"
assert_jq \
    "(x1) terminal threshold compaction: salvaged as success" \
    "$WD_X1_ENVELOPE" \
    ".result.status" \
    "success"

# (x1a) The group kill also drains inherited stream FDs; no descendant may
# retain the filter pipe after post-result salvage.
DRAIN_DESCENDANT_PID="$BASE_TMP/drain-descendant.pid"
WD_X1A_EXIT=0
WD_X1A_START=$(date +%s)
(
    export PATH="$WATCHDOG_DRAIN_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export FIXTURE_PATH="$COMPACTION_AFTER_RESULT"
    export PI_DESCENDANT_PID_PATH="$DRAIN_DESCENDANT_PID"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=10
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x1a_stderr.log"
) >"$BASE_TMP/wd_x1a_envelope.json" || WD_X1A_EXIT=$?
WD_X1A_ELAPSED=$(($(date +%s) - WD_X1A_START))

if [[ "$WD_X1A_EXIT" -eq 0 ]] && [[ "$WD_X1A_ELAPSED" -lt 5 ]] && [[ -s "$DRAIN_DESCENDANT_PID" ]] &&
    ! kill -0 "$(<"$DRAIN_DESCENDANT_PID")" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x1a) post-result kill drains filter and descendants\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x1a) post-result stream drain failed: exit=%s elapsed=%ss descendant=%s\n' \
        "$WD_X1A_EXIT" "$WD_X1A_ELAPSED" "$(<"$DRAIN_DESCENDANT_PID" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

# (x2) A threshold compaction event BEFORE agent_end is not post-result
# maintenance. It must wait through the ordinary result grace rather than
# incorrectly taking the immediate salvage branch.
COMPACTION_BEFORE_RESULT="$BASE_TMP/compaction_before_result.jsonl"
printf '%s\n' \
    '{"type":"compaction_start","reason":"threshold"}' \
    '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"done"}]}]}' \
    >"$COMPACTION_BEFORE_RESULT"
WD_X2_EXIT=0
(
    export PATH="$WATCHDOG_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export FIXTURE_PATH="$COMPACTION_BEFORE_RESULT"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=1
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x2_stderr.log"
) >"$BASE_TMP/wd_x2_envelope.json" || WD_X2_EXIT=$?

if [[ "$WD_X2_EXIT" -eq 0 ]] && ! grep -qF "canceled post-result Pi compaction" "$BASE_TMP/wd_x2_stderr.log"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x2) pre-result compaction does not take immediate salvage\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x2) pre-result compaction took immediate salvage or failed: %s\n' "$(cat "$BASE_TMP/wd_x2_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

# (x3) Raw stderr can contain JSON-looking text. It is not a terminal Pi
# event: only parsed JSONL agent_end records may start result grace.
FAKE_AGENT_END="$BASE_TMP/fake_agent_end_stderr.jsonl"
printf '%s\n' 'provider warning: {"type":"agent_end"}' >"$FAKE_AGENT_END"
WD_X3_EXIT=0
(
    export PATH="$WATCHDOG_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export FIXTURE_PATH="$FAKE_AGENT_END"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=1
    export CODEGEN_CALL_IDLE_CAP_SECS=2
    export CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x3_stderr.log"
) >"$BASE_TMP/wd_x3_envelope.json" || WD_X3_EXIT=$?

if [[ "$WD_X3_EXIT" -eq 0 ]] && ! grep -qF "agent_end already emitted" "$BASE_TMP/wd_x3_stderr.log"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x3) raw JSON-looking stderr does not start result grace\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x3) raw JSON-looking stderr started result grace or failed: %s\n' "$(cat "$BASE_TMP/wd_x3_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

# (x4) Filter startup/write failure is transport-fatal, never a partial green
# envelope. A PATH-local node stub fails only the filter process.
FILTER_FAILURE_STUB_DIR="$BASE_TMP/filter_failure_stub_bin"
mkdir -p "$FILTER_FAILURE_STUB_DIR"
cat >"$FILTER_FAILURE_STUB_DIR/node" <<'NODEFAIL'
#!/usr/bin/env bash
printf 'forced filter failure\n' >&2
exit 23
NODEFAIL
chmod +x "$FILTER_FAILURE_STUB_DIR/node"
WD_X4_EXIT=0
(
    export PATH="$FILTER_FAILURE_STUB_DIR:$STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export FIXTURE_PATH="$FIXTURES_DIR/pi_success_text.jsonl"
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x4_stderr.log"
) >"$BASE_TMP/wd_x4_envelope.json" || WD_X4_EXIT=$?

if [[ "$WD_X4_EXIT" -ne 0 ]] && grep -qF "Pi stream filter failed (exit 23): forced filter failure" "$BASE_TMP/wd_x4_stderr.log" &&
    [[ ! -s "$BASE_TMP/wd_x4_envelope.json" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x4) filter failure exits non-zero without envelope\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (x4) filter failure was not fatal: exit=%s stderr=%s envelope=%s\n' \
        "$WD_X4_EXIT" "$(<"$BASE_TMP/wd_x4_stderr.log")" "$(<"$BASE_TMP/wd_x4_envelope.json")"
    fail=$((fail + 1))
fi

# (x4a) Hanging Pi plus filter failure: every filter-fatal path must terminate
# and reap the producer process group before returning non-zero.
FILTER_FAILURE_HANGING_STUB_DIR="$BASE_TMP/filter_failure_hanging_stub_bin"
mkdir -p "$FILTER_FAILURE_HANGING_STUB_DIR"
cat >"$FILTER_FAILURE_HANGING_STUB_DIR/node" <<'NODEHANGFAIL'
#!/usr/bin/env bash
sleep 0.2
printf 'forced hanging filter failure
' >&2
exit 23
NODEHANGFAIL
chmod +x "$FILTER_FAILURE_HANGING_STUB_DIR/node"
WD_X4A_PI_PID="$BASE_TMP/wd_x4a_pi.pid"
WD_X4A_EXIT=0
WD_X4A_START=$(date +%s)
(
    export PATH="$FILTER_FAILURE_HANGING_STUB_DIR:$WATCHDOG_STALL_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export PI_STUB_PID_PATH="$WD_X4A_PI_PID"
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_x4a_stderr.log"
) >"$BASE_TMP/wd_x4a_envelope.json" || WD_X4A_EXIT=$?
WD_X4A_ELAPSED=$(($(date +%s) - WD_X4A_START))

WD_X4A_ALIVE=0
if [[ -s "$WD_X4A_PI_PID" ]] && kill -0 "$(<"$WD_X4A_PI_PID")" 2>/dev/null; then
    WD_X4A_ALIVE=1
    kill -KILL "$(<"$WD_X4A_PI_PID")" 2>/dev/null || true
fi

if [[ "$WD_X4A_EXIT" -ne 0 ]] &&
    grep -qF "Pi stream filter failed (exit 23): forced hanging filter failure" "$BASE_TMP/wd_x4a_stderr.log" &&
    [[ ! -s "$BASE_TMP/wd_x4a_envelope.json" ]] &&
    [[ -s "$WD_X4A_PI_PID" ]] && [[ "$WD_X4A_ALIVE" -eq 0 ]] &&
    [[ "$WD_X4A_ELAPSED" -lt 20 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x4a) filter failure terminates hanging Pi group
'
    pass=$((pass + 1))
else
    printf 'FAIL: (x4a) hanging filter cleanup failed: exit=%s alive=%s elapsed=%ss stderr=%s
' \
        "$WD_X4A_EXIT" "$WD_X4A_ALIVE" "$WD_X4A_ELAPSED" \
        "$(cat "$BASE_TMP/wd_x4a_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

# (y) No-terminal/no-tool stall: stream and idle caps are deliberately
# distinct. The actual Pi process has no children, so the 1s stream-idle path
# must fire instead of waiting for the 10s generic idle cap.
WD_Y_EXIT=0
WD_Y_START=$(date +%s)
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
    export CODEGEN_CALL_IDLE_CAP_SECS=10
    export CODEGEN_CALL_STREAM_IDLE_SECS=1
    export CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_y_stderr.log"
) >"$BASE_TMP/wd_y_envelope.json" || WD_Y_EXIT=$?
WD_Y_ELAPSED=$(($(date +%s) - WD_Y_START))

if [[ "$WD_Y_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (y) watchdog no-tool stall exits 0 (not 1)\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (y) watchdog no-tool stall exits 0 — got %d\n' "$WD_Y_EXIT"
    fail=$((fail + 1))
fi

WD_Y_ENVELOPE="$(cat "$BASE_TMP/wd_y_envelope.json")"
assert_jq \
    "(y) watchdog no-tool stall: result.status == failed" \
    "$WD_Y_ENVELOPE" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(y) watchdog no-tool stall: reason contains retryable taxonomy token" \
    "$WD_Y_ENVELOPE" \
    '(.result.reason // "") | test("Stream idle timeout")'

if grep -qF "stream idle 1s, no tool subprocess" "$BASE_TMP/wd_y_stderr.log" 2>/dev/null &&
    ! grep -qF "idle 10s with no output growth" "$BASE_TMP/wd_y_stderr.log" 2>/dev/null &&
    [[ "$WD_Y_ELAPSED" -lt 8 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (y) no-tool stall takes stream-idle path (%ds)\n' "$WD_Y_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (y) no-tool stall missed stream-idle path: elapsed=%ss stderr=%s\n' \
        "$WD_Y_ELAPSED" "$(cat "$BASE_TMP/wd_y_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

# (y1) A live child of the actual Pi process represents a running tool. The
# 1s stream-idle path must stay suppressed; the 3s generic idle cap remains the
# backstop and proves the topology check does not false-kill active tools.
WD_Y1_EXIT=0
WD_Y1_START=$(date +%s)
(
    export PATH="$WATCHDOG_TOOL_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=3
    export CODEGEN_CALL_STREAM_IDLE_SECS=1
    export CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_y1_stderr.log"
) >"$BASE_TMP/wd_y1_envelope.json" || WD_Y1_EXIT=$?
WD_Y1_ELAPSED=$(($(date +%s) - WD_Y1_START))

if [[ "$WD_Y1_EXIT" -eq 0 ]] &&
    grep -qF "idle 3s with no output growth" "$BASE_TMP/wd_y1_stderr.log" 2>/dev/null &&
    ! grep -qF "stream idle 1s, no tool subprocess" "$BASE_TMP/wd_y1_stderr.log" 2>/dev/null &&
    [[ "$WD_Y1_ELAPSED" -ge 3 ]] && [[ "$WD_Y1_ELAPSED" -lt 10 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (y1) live tool suppresses stream-idle path (%ds)\n' "$WD_Y1_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (y1) live tool did not defer to idle cap: exit=%s elapsed=%ss stderr=%s\n' \
        "$WD_Y1_EXIT" "$WD_Y1_ELAPSED" "$(cat "$BASE_TMP/wd_y1_stderr.log" 2>/dev/null || true)"
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

# (z1) Pi can exit while a tool descendant still owns stdout. Producer status
# must trigger process-group cleanup so filter EOF cannot wedge one-shot calls.
ORPHAN_STUB_DIR="$BASE_TMP/orphan_drain_stub_bin"
mkdir -p "$ORPHAN_STUB_DIR"
cat >"$ORPHAN_STUB_DIR/pi.body" <<'ORPHANSTUB'
#!/usr/bin/env bash
cat "$FIXTURE_PATH"
sleep 3600 &
printf '%s' "$!" >"$PI_DESCENDANT_PID_PATH"
exit 0
ORPHANSTUB
link_stub_path "$ORPHAN_STUB_DIR/pi"
ORPHAN_DESCENDANT_PID="$BASE_TMP/orphan-descendant.pid"
ORPHAN_EXIT=0
(
    export PATH="$ORPHAN_STUB_DIR:$PATH"
    for v in "${BASE_ENV[@]}"; do export "$v"; done
    export FIXTURE_PATH="$FIXTURES_DIR/pi_success_text.jsonl"
    export PI_DESCENDANT_PID_PATH="$ORPHAN_DESCENDANT_PID"
    unset CODEGEN_LOOP 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/orphan_stderr.log"
) >"$BASE_TMP/orphan_envelope.json" &
ORPHAN_DISPATCH_PID=$!
ORPHAN_FINISHED=0
for _ in $(seq 1 120); do
    if ! kill -0 "$ORPHAN_DISPATCH_PID" 2>/dev/null; then
        ORPHAN_FINISHED=1
        break
    fi
    sleep 0.1
done
if [[ "$ORPHAN_FINISHED" -eq 0 ]]; then
    pkill -TERM -P "$ORPHAN_DISPATCH_PID" 2>/dev/null || true
    kill -TERM "$ORPHAN_DISPATCH_PID" 2>/dev/null || true
fi
wait "$ORPHAN_DISPATCH_PID" || ORPHAN_EXIT=$?
ORPHAN_ALIVE=0
if [[ -s "$ORPHAN_DESCENDANT_PID" ]] && kill -0 "$(<"$ORPHAN_DESCENDANT_PID")" 2>/dev/null; then
    ORPHAN_ALIVE=1
    kill -KILL "$(<"$ORPHAN_DESCENDANT_PID")" 2>/dev/null || true
fi
ORPHAN_STATUS="$(jq -r '.result.status // empty' "$BASE_TMP/orphan_envelope.json" 2>/dev/null || true)"
if [[ "$ORPHAN_EXIT" -eq 0 ]] && [[ "$ORPHAN_FINISHED" -eq 1 ]] &&
    [[ "$ORPHAN_ALIVE" -eq 0 ]] && [[ "$ORPHAN_STATUS" == "success" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (z1) producer exit drains orphaned tool descendant\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (z1) orphan drain: exit=%s finished=%s alive=%s status=%s stderr=%s\n' \
        "$ORPHAN_EXIT" "$ORPHAN_FINISHED" "$ORPHAN_ALIVE" "$ORPHAN_STATUS" \
        "$(<"$BASE_TMP/orphan_stderr.log")"
    fail=$((fail + 1))
fi

# (i1) Active execution uses immutable dispatcher/filter bytes. Replacing the
# tracked sources after snapshot creation must not alter the envelope.
IMMUTABLE_ROOT="$BASE_TMP/immutable-source"
mkdir -p "$IMMUTABLE_ROOT/harnesses/pi" "$IMMUTABLE_ROOT/harnesses/claude/hooks/lib" "$IMMUTABLE_ROOT/bin" "$IMMUTABLE_ROOT/tmp"
cp "$DISPATCH_SCRIPT" "$IMMUTABLE_ROOT/harnesses/pi/call-dispatch.sh"
cp "$(dirname "$DISPATCH_SCRIPT")/pi-jsonl-filter.cjs" "$IMMUTABLE_ROOT/harnesses/pi/pi-jsonl-filter.cjs"
cp "$HOOKS_DIR/lib/schema-validate.js" "$IMMUTABLE_ROOT/harnesses/claude/hooks/lib/schema-validate.js"
cat >"$IMMUTABLE_ROOT/bin/pi" <<'IMMUTABLEPI'
#!/usr/bin/env bash
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"snapshot survived"}]}]}' '{"type":"agent_settled"}'
exec perl -e 'select undef, undef, undef, 10'
IMMUTABLEPI
chmod +x "$IMMUTABLE_ROOT/bin/pi"
IMMUTABLE_EXIT=0
env TMPDIR="$IMMUTABLE_ROOT/tmp" PATH="$IMMUTABLE_ROOT/bin:$PATH" CODEGEN_LOOP=1 CODEGEN_CALL_MODEL=test-model CODEGEN_CALL_EFFORT=low CODEGEN_CALL_PROMPT=test CODEGEN_CALL_SYSTEM_PROMPT=test CODEGEN_CALL_RESULT_GRACE_SECS=1 CODEGEN_CALL_POLL_SECS=0.1 /bin/bash "$IMMUTABLE_ROOT/harnesses/pi/call-dispatch.sh" >"$IMMUTABLE_ROOT/envelope.json" 2>"$IMMUTABLE_ROOT/stderr.log" &
IMMUTABLE_PID=$!
IMMUTABLE_SNAPSHOT=""
for _ in $(seq 1 100); do
    for candidate in "$IMMUTABLE_ROOT/tmp"/codegen-pi-dispatch.*; do
        if [[ -s "$candidate/call-dispatch.sh" ]] && [[ -s "$candidate/pi-jsonl-filter.cjs" ]]; then
            IMMUTABLE_SNAPSHOT="$candidate"
            break 2
        fi
    done
    sleep 0.05
done
if [[ -n "$IMMUTABLE_SNAPSHOT" ]]; then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 97' >"$IMMUTABLE_ROOT/harnesses/pi/call-dispatch.sh"
    printf '%s\n' 'process.exit(98);' >"$IMMUTABLE_ROOT/harnesses/pi/pi-jsonl-filter.cjs"
else
    kill "$IMMUTABLE_PID" 2>/dev/null || true
fi
wait "$IMMUTABLE_PID" || IMMUTABLE_EXIT=$?
IMMUTABLE_STATUS="$(jq -r '.result.status // empty' "$IMMUTABLE_ROOT/envelope.json" 2>/dev/null || true)"
IMMUTABLE_VALUE="$(jq -r '.result.value // empty' "$IMMUTABLE_ROOT/envelope.json" 2>/dev/null || true)"
IMMUTABLE_LEAK=""
for candidate in "$IMMUTABLE_ROOT/tmp"/codegen-pi-dispatch.*; do
    [[ ! -d "$candidate" ]] || IMMUTABLE_LEAK="$candidate"
done
if [[ "$IMMUTABLE_EXIT" -eq 0 ]] && [[ "$IMMUTABLE_STATUS" == "success" ]] && [[ "$IMMUTABLE_VALUE" == "snapshot survived" ]] && [[ -z "$IMMUTABLE_LEAK" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (i1) immutable dispatcher/filter survive tracked-source replacement\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (i1) immutable source: exit=%s status=%s value=%s leak=%s stderr=%s\n' "$IMMUTABLE_EXIT" "$IMMUTABLE_STATUS" "$IMMUTABLE_VALUE" "$IMMUTABLE_LEAK" "$(<"$IMMUTABLE_ROOT/stderr.log")"
    fail=$((fail + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
