#!/usr/bin/env bash
# pi-dispatch_test.sh — unit tests for harnesses/pi/call-dispatch.sh
#
# Uses a PATH-override stub 'pi' that emits agent_end JSONL fixtures,
# so no real pi/LLM calls are made.
#
# Cases:
#   (1) success no-schema: text, no trailing "?" → status=success
#   (2) clarifying no-schema: text ends "?" → status=clarifying_question
#   (3) schema set + valid JSON → status=success, result.value is object
#   (4) schema set + reply ends "?" (asymmetry guard) → status NOT clarifying_question
#   (5) schema-validate FAIL: JSON omits required field → status=failed, reason~schema

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SCRIPT="$(cd "$HOOKS_DIR/../../pi" && pwd)/call-dispatch.sh"
FIXTURES_DIR="$HOOKS_DIR/fixtures"

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
cat >"$STUB_DIR/pi" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub pi: ignore all args, emit fixture JSONL to stdout, exit 0
exec cat "$FIXTURE_PATH"
STUB_EOF
chmod +x "$STUB_DIR/pi"

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

# ── Case (2): clarifying no-schema — text ends "?" ────────────────────────────
ENVELOPE2="$(run_dispatch "$FIXTURES_DIR/pi_clarifying_question.jsonl")"

assert_jq \
    "(2) clarifying no-schema: result.status" \
    "$ENVELOPE2" \
    ".result.status" \
    "clarifying_question"

assert_jq_truthy \
    "(2) clarifying no-schema: clarifying_question field ends ?" \
    "$ENVELOPE2" \
    '(.result.clarifying_question // "") | test("\\?[[:space:]]*$")'

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

# ── Case (4): schema set + reply ends "?" → NOT clarifying_question ───────────
ENVELOPE4="$(run_dispatch "$FIXTURES_DIR/pi_schema_cq_asymmetry.jsonl" "CODEGEN_CALL_JSON_SCHEMA=$SCHEMA")"

assert_jq_not_equal \
    "(4) schema+CQ asymmetry guard: status must not be clarifying_question" \
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

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
