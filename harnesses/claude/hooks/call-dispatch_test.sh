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

assert_file_contains() {
    local filepath="$1"
    local needle="$2"
    if grep -qF -- "$needle" "$filepath" 2>/dev/null; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s contains %q\n' "$filepath" "$needle"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s does not contain %q\n' "$filepath" "$needle"
        fail=$((fail + 1))
    fi
}

assert_file_absent() {
    local filepath="$1"
    local needle="$2"
    if grep -qF -- "$needle" "$filepath" 2>/dev/null; then
        printf 'FAIL: %s contains unexpected %q\n' "$filepath" "$needle"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s absent %q\n' "$filepath" "$needle"
        pass=$((pass + 1))
    fi
}

assert_log_contains_line() {
    local logpath="$1"
    local needle="$2"
    local desc="${3:-$logpath contains line $needle}"
    if grep -qFx -- "$needle" "$logpath" 2>/dev/null; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — log:\n%s\n' "$desc" "$(cat "$logpath" 2>/dev/null || true)"
        fail=$((fail + 1))
    fi
}

assert_log_absent_line() {
    local logpath="$1"
    local needle="$2"
    local desc="${3:-$logpath absent line $needle}"
    if grep -qFx -- "$needle" "$logpath" 2>/dev/null; then
        printf 'FAIL: %s — unexpectedly present. log:\n%s\n' "$desc" "$(cat "$logpath" 2>/dev/null || true)"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

assert_log_line_after() {
    # Asserts that the line immediately following the (first) line matching
    # $anchor equals $expected.
    local logpath="$1"
    local anchor="$2"
    local expected="$3"
    local desc="${4:-line after $anchor is $expected}"
    local actual
    actual="$(grep -A1 -Fx -- "$anchor" "$logpath" 2>/dev/null | sed -n '2p')"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — got %q\n  log:\n%s\n' "$desc" "$actual" "$(cat "$logpath" 2>/dev/null || true)"
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

# session_id is threaded into the envelope from the result event
assert_jq \
    "envelope carries session_id from result event" \
    "$ENVELOPE" \
    ".session_id" \
    "test-session-abc123"

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

# ── Static source-assertion: MAX_THINKING_TOKENS=0 regression guard ──────────
HARNESSES_DIR="$(cd "$HOOKS_DIR/.." && pwd)"
CODEGEN_DIR="$(cd "$HARNESSES_DIR/../.." && pwd)"

# Test 1: call-dispatch.sh sets MAX_THINKING_TOKENS=0
assert_file_contains "$HARNESSES_DIR/call-dispatch.sh" "MAX_THINKING_TOKENS=0"

# Test 2: call-dispatch.sh preserves the non-agent default scope (thinking-off)
assert_file_contains "$HARNESSES_DIR/call-dispatch.sh" 'SETTING_SOURCES="project"'

# Test 3: dispatch.sh always execs the Elixir loop, which calls
# call-dispatch.sh per-role (Test 1 covers MAX_THINKING_TOKENS=0 there).
# dispatch.sh itself no longer invokes `claude` directly, so it carries no
# MAX_THINKING_TOKENS setting of its own.

# Test 4: claude-code-settings.json has installed-settings copy
assert_file_contains "$HARNESSES_DIR/claude-code-settings.json" '"MAX_THINKING_TOKENS": "0"'

# Test 5: claude-debug.sh (thinking-ON launcher) has --settings overlay with MAX_THINKING_TOKENS
assert_file_contains "$HARNESSES_DIR/claude-debug.sh" "--settings"
assert_file_contains "$HARNESSES_DIR/claude-debug.sh" "MAX_THINKING_TOKENS"

# Test 6: claude-shape.sh (thinking-ON launcher) has --settings overlay with MAX_THINKING_TOKENS
assert_file_contains "$HARNESSES_DIR/claude-shape.sh" "--settings"
assert_file_contains "$HARNESSES_DIR/claude-shape.sh" "MAX_THINKING_TOKENS"

# Test 7: claude-ops.sh (thinking-OFF launcher, inherits user-scope =0) has NO MAX_THINKING_TOKENS
assert_file_absent "$HARNESSES_DIR/claude-ops.sh" "MAX_THINKING_TOKENS"

# Test 8-11: interactive launchers carry CLAUDE_AFK_TIMEOUT_MS
assert_file_contains "$HARNESSES_DIR/claude-shape.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-debug.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-experiment.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-ops.sh" "CLAUDE_AFK_TIMEOUT_MS"

# Test 12: ops now passes --settings (AFK-only interactive overlay)
assert_file_contains "$HARNESSES_DIR/claude-ops.sh" "--settings"

# Test 13: experiment preserves API_FORCE_IDLE_TIMEOUT (regression guard)
assert_file_contains "$HARNESSES_DIR/claude-experiment.sh" "API_FORCE_IDLE_TIMEOUT"

# ── Persist-always: --no-session-persistence is gone ─────────────────────────
assert_file_absent "$HARNESSES_DIR/call-dispatch.sh" "--no-session-persistence"

# ── Pi divergence: --no-session persists only in absence of --resume ────────
PI_DISPATCH_SRC="$(cd "$HOOKS_DIR/../../pi" && pwd)/call-dispatch.sh"
assert_file_contains "$PI_DISPATCH_SRC" "--session-id"

# ── Durable transcript capture (CODEGEN_CALL_TRANSCRIPT_PATH) ────────────────

# (d) Runtime capture: env var set → transcript copied to dest (nested mkdir -p)
(
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
    export CODEGEN_CALL_TRANSCRIPT_PATH="$BASE_TMP/cap/nested/out.jsonl"
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/cap_envelope.json" 2>/dev/null || true

if [[ -f "$BASE_TMP/cap/nested/out.jsonl" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (d) transcript copied to nested dest\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (d) transcript not copied to nested dest %s\n' "$BASE_TMP/cap/nested/out.jsonl"
    fail=$((fail + 1))
fi

assert_file_contains "$BASE_TMP/cap/nested/out.jsonl" "PLATFORM_QUESTION"

# (e) Unset: no env var → no durable capture file created
(
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
    unset CODEGEN_CALL_TRANSCRIPT_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/nocap_envelope.json" 2>/dev/null || true

if [[ -f "$BASE_TMP/nocap.jsonl" ]]; then
    printf 'FAIL: (e) unexpected durable capture file created without env var\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (e) no durable capture file without env var\n'
    pass=$((pass + 1))
fi

assert_jq \
    "(e) unset transcript path: result.status still success" \
    "$(cat "$BASE_TMP/nocap_envelope.json")" \
    ".result.status" \
    "success"

# (f) Failure non-blocking: unwritable dest → dispatch still emits envelope + exits normally
(
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
    export CODEGEN_CALL_TRANSCRIPT_PATH="/dev/null/cannot"
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/fail_stderr.log"
) >"$BASE_TMP/fail_envelope.json" 2>/dev/null
fail_exit=$?

if [[ "$fail_exit" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (f) dispatch exits normally despite unwritable transcript dest\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (f) dispatch exit code changed by transcript copy failure — got %d\n' "$fail_exit"
    fail=$((fail + 1))
fi

assert_jq \
    "(f) unwritable transcript dest: result.status still success" \
    "$(cat "$BASE_TMP/fail_envelope.json")" \
    ".result.status" \
    "success"

# Test 14-15: source-assertions — both claude and pi call-dispatch.sh honor the env var
assert_file_contains "$HARNESSES_DIR/call-dispatch.sh" "CODEGEN_CALL_TRANSCRIPT_PATH"

PI_DISPATCH="$(cd "$HOOKS_DIR/../../pi" && pwd)/call-dispatch.sh"
assert_file_contains "$PI_DISPATCH" "CODEGEN_CALL_TRANSCRIPT_PATH"

# ── Flag-assembly stub: logs argv, then emits fixture ────────────────────────
ARGV_STUB_DIR="$BASE_TMP/argv_stub_bin"
mkdir -p "$ARGV_STUB_DIR"
cat >"$ARGV_STUB_DIR/claude" <<'ARGVSTUB'
#!/usr/bin/env bash
# Log every arg on its own line, then emit the fixture (no exec — statements after must run)
: >"$ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$ARGV_LOG"; done
cat "$FIXTURE_PATH"
ARGVSTUB
chmod +x "$ARGV_STUB_DIR/claude"

# (g) AGENT set, no explicit tools → user,project scope; --agent present; --tools omitted
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_g.log"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="developer-static"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_g_stderr.log" || true
)

assert_log_line_after "$BASE_TMP/argv_g.log" "--setting-sources" "user,project" \
    "(g) agent set: --setting-sources followed by user,project"
assert_log_contains_line "$BASE_TMP/argv_g.log" "--agent" "(g) agent set: --agent flag present"
assert_log_contains_line "$BASE_TMP/argv_g.log" "developer-static" "(g) agent set: agent name present"
assert_log_absent_line "$BASE_TMP/argv_g.log" "--tools" "(g) agent + no explicit tools: --tools flag omitted"

# (h) NO agent (one-shot system-prompt call) → project-only scope; deny-all --tools ""
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_h.log"
    export FIXTURE_PATH="$FIXTURE"
    unset CODEGEN_CALL_AGENT 2>/dev/null || true
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_h_stderr.log" || true
)

assert_log_line_after "$BASE_TMP/argv_h.log" "--setting-sources" "project" \
    "(h) no agent: --setting-sources followed by project"
assert_log_line_after "$BASE_TMP/argv_h.log" "--tools" "" \
    "(h) no agent, no explicit tools: --tools followed by empty (deny-all)"
assert_log_contains_line "$BASE_TMP/argv_h.log" "--append-system-prompt" \
    "(h) no agent: --append-system-prompt present"

# (i) AGENT set + explicit tools → user,project scope; --tools carries explicit list
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_i.log"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="developer-static"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    export CODEGEN_CALL_ALLOWED_TOOLS_SET=1
    export CODEGEN_CALL_ALLOWED_TOOLS="Read Edit"
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_i_stderr.log" || true
)

assert_log_line_after "$BASE_TMP/argv_i.log" "--tools" "Read Edit" \
    "(i) agent + explicit tools: --tools followed by explicit list"
assert_log_line_after "$BASE_TMP/argv_i.log" "--setting-sources" "user,project" \
    "(i) agent + explicit tools: --setting-sources followed by user,project"

# (j) CODEGEN_CALL_RESUME set → --resume threaded with the session id
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_j.log"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="developer-static"
    export CODEGEN_CALL_RESUME="warm-session-xyz"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_j_stderr.log" || true
)

assert_log_contains_line "$BASE_TMP/argv_j.log" "--resume" "(j) CODEGEN_CALL_RESUME set: --resume flag present"
assert_log_line_after "$BASE_TMP/argv_j.log" "--resume" "warm-session-xyz" \
    "(j) CODEGEN_CALL_RESUME set: --resume followed by session id"

# (k) CODEGEN_CALL_RESUME unset → no --resume flag threaded
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_k.log"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="developer-static"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_k_stderr.log" || true
)

assert_log_absent_line "$BASE_TMP/argv_k.log" "--resume" "(k) CODEGEN_CALL_RESUME unset: --resume flag absent"

# ── RED-then-GREEN proof for FIX-1/FIX-3 (case g) ────────────────────────────
# Synthetic pre-fix fixture (NOT git HEAD): a floating `git show HEAD:` compare
# self-invalidates permanently once the fix lands and becomes part of HEAD —
# every future run then "pulls the pre-fix source" and gets the ALREADY-FIXED
# script, so the RED assertion can never fire again. A hardcoded synthetic
# fixture reproducing the historical bug (hardcoded "project" scope regardless
# of --agent) stays a stable, permanent regression proof that the (g)
# assertion (lines ~439-443 above, which runs against the LIVE script every
# time) is load-bearing — not a vacuous grep.
PRE_FIX_SCRIPT="$BASE_TMP/call-dispatch.pre.sh"
cat >"$PRE_FIX_SCRIPT" <<'PREFIX'
#!/usr/bin/env bash
# Synthetic reproduction of the pre-fix bug: --setting-sources hardcoded to
# "project" regardless of whether CODEGEN_CALL_AGENT is set.
set -euo pipefail
AGENT="${CODEGEN_CALL_AGENT:-}"
SETTING_SOURCES="project"
ARGS=(claude --setting-sources "$SETTING_SOURCES")
if [ -n "$AGENT" ]; then
    ARGS+=(--agent "$AGENT")
fi
exec "${ARGS[@]}"
PREFIX
chmod +x "$PRE_FIX_SCRIPT"

(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_g_red.log"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="developer-static"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$PRE_FIX_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_g_red_stderr.log" || true
)

# Pre-fix source hardcodes "project" scope even with AGENT set — the fixed
# assertion (user,project) must NOT match against the pre-fix log, proving
# the new assertion is load-bearing (would have caught the bug).
RED_SCOPE="$(grep -A1 -Fx -- '--setting-sources' "$BASE_TMP/argv_g_red.log" 2>/dev/null | sed -n '2p')"
if [[ "$RED_SCOPE" != "user,project" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: RED-then-GREEN — pre-fix source fails the (g) scope assertion as expected\n'
    pass=$((pass + 1))
else
    printf 'FAIL: RED-then-GREEN — pre-fix source unexpectedly satisfies the (g) scope assertion (got %q)\n' "$RED_SCOPE"
    fail=$((fail + 1))
fi

rm -f "$PRE_FIX_SCRIPT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
