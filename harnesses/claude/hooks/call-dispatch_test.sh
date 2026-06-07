#!/usr/bin/env bash
# call-dispatch_test.sh — unit tests for harnesses/claude/call-dispatch.sh
#
# Regression-guards:
#   Bug 3a: leading non-JSON warning line in stream does not break parsing
#   Bug 3b: .structured_output from result event is extracted into .result.value
#
# Uses a PATH-override stub claude that emits the bouncer_classify_structured.jsonl
# fixture, so no real claude calls are made.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SCRIPT="$(cd "$HOOKS_DIR/.." && pwd)/call-dispatch.sh"
FIXTURE="$HOOKS_DIR/fixtures/bouncer_classify_structured.jsonl"
FIXTURE_CQ="$HOOKS_DIR/fixtures/clarifying_question.jsonl"
FIXTURE_ERR="$HOOKS_DIR/fixtures/is_error.jsonl"
FIXTURE_SCHEMA_FAIL="$HOOKS_DIR/fixtures/schema_validate_fail.jsonl"

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

# ── Setup ─────────────────────────────────────────────────────────────────────
BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

# Create a PATH-override stub 'claude' that emits the fixture and exits 0
STUB_DIR="$BASE_TMP/stub_bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/claude" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub claude: ignore all args, emit fixture to stdout, exit 0
exec cat "$FIXTURE_PATH"
STUB_EOF
chmod +x "$STUB_DIR/claude"

# Export fixture path for the stub
export FIXTURE_PATH="$FIXTURE"

# Override PATH so the stub is found first
export PATH="$STUB_DIR:$PATH"

# ── Set required CODEGEN_CALL_* env vars ──────────────────────────────────────
export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
export CODEGEN_CALL_MODEL="claude-haiku-4-5"
export CODEGEN_CALL_EFFORT="low"
export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
# Leave CODEGEN_CALL_ALLOWED_TOOLS_SET unset to use default empty tools path
unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true

# ── Run call-dispatch.sh and capture stdout envelope ─────────────────────────
actual_exit=0
ENVELOPE="$(bash "$DISPATCH_SCRIPT" 2>/dev/null)" || actual_exit=$?

# ── Assertions ────────────────────────────────────────────────────────────────

# result.status == "success"
assert_jq \
    "result.status is success" \
    "$ENVELOPE" \
    ".result.status" \
    "success"

# result.value is an object (structured_output extracted — Bug 3b)
assert_jq_truthy \
    "result.value is object (Bug 3b: structured_output extracted)" \
    "$ENVELOPE" \
    '(.result.value | type) == "object"'

# result.value.intent == "PLATFORM_QUESTION" (correct value from structured_output)
assert_jq \
    "result.value.intent == PLATFORM_QUESTION (Bug 3b: correct structured value)" \
    "$ENVELOPE" \
    ".result.value.intent" \
    "PLATFORM_QUESTION"

# result.value is not null (proves structured_output was used, not empty .result)
assert_jq_truthy \
    "result.value is not null (Bug 3a+3b: warning line skipped, structured_output populated)" \
    "$ENVELOPE" \
    '.result.value != null'

# exit code should be 0
if [[ "$actual_exit" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: dispatch exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: dispatch exits 0 — got exit %d\n' "$actual_exit"
    fail=$((fail + 1))
fi

# ── Case (a): clarifying-question — no JSON schema, text ends "?" ─────────────
(
    export FIXTURE_PATH="$FIXTURE_CQ"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Tell me something."
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/cq_envelope.json" 2>/dev/null || true

CQ_ENVELOPE="$(cat "$BASE_TMP/cq_envelope.json")"

assert_jq \
    "(a) clarifying_question: result.status" \
    "$CQ_ENVELOPE" \
    ".result.status" \
    "clarifying_question"

assert_jq_truthy \
    "(a) clarifying_question: clarifying_question field ends ?" \
    "$CQ_ENVELOPE" \
    '(.result.clarifying_question // "") | test("\\?[[:space:]]*$")'

# ── Case (b): failed — is_error:true in fixture ───────────────────────────────
(
    export FIXTURE_PATH="$FIXTURE_ERR"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do something."
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/err_envelope.json" 2>/dev/null || true

ERR_ENVELOPE="$(cat "$BASE_TMP/err_envelope.json")"

assert_jq \
    "(b) is_error: result.status == failed" \
    "$ERR_ENVELOPE" \
    ".result.status" \
    "failed"

# ── Case (c): schema-validate FAIL — structured_output missing required field ─
(
    export FIXTURE_PATH="$FIXTURE_SCHEMA_FAIL"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this."
    export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/schema_fail_envelope.json" 2>/dev/null || true

SCHEMA_FAIL_ENVELOPE="$(cat "$BASE_TMP/schema_fail_envelope.json")"

assert_jq \
    "(c) schema-validate FAIL: result.status == failed" \
    "$SCHEMA_FAIL_ENVELOPE" \
    ".result.status" \
    "failed"

assert_jq_truthy \
    "(c) schema-validate FAIL: reason contains 'schema'" \
    "$SCHEMA_FAIL_ENVELOPE" \
    '(.result.reason // "") | test("schema")'

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
