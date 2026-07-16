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
FIXTURE_QMARK="$HOOKS_DIR/fixtures/question_mark_reply.jsonl"
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

# ── Case (a): question-mark reply, no schema → success (NOT a clarifying question) ──
(
    export FIXTURE_PATH="$FIXTURE_QMARK"
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
) >"$BASE_TMP/qmark_envelope.json" 2>/dev/null || true

QMARK_ENVELOPE="$(cat "$BASE_TMP/qmark_envelope.json")"

assert_jq \
    "(a) question-mark reply: result.status" \
    "$QMARK_ENVELOPE" \
    ".result.status" \
    "success"

assert_jq_truthy \
    "(a) question-mark reply: result.value ends ?" \
    "$QMARK_ENVELOPE" \
    '(.result.value // "") | test("\\?[[:space:]]*$")'

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

# (i2) CODEGEN_CALL_AGENTS_PATH set → --agents threaded with the file content verbatim
AGENTS_FIXTURE="$BASE_TMP/agents_fixture.json"
printf '{"probe-agent":{"description":"probe","prompt":"probe","tools":[]}}' >"$AGENTS_FIXTURE"
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_i2.log"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="probe-agent"
    export CODEGEN_CALL_AGENTS_PATH="$AGENTS_FIXTURE"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_i2_stderr.log" || true
)

assert_log_contains_line "$BASE_TMP/argv_i2.log" "--agents" "(i2) CODEGEN_CALL_AGENTS_PATH set: --agents flag present"
assert_log_contains_line "$BASE_TMP/argv_i2.log" "probe-agent" "(i2) --agents carries the file content verbatim"

# (i3) CODEGEN_CALL_AGENTS_PATH unset → --agents flag absent
(
    export PATH="$ARGV_STUB_DIR:$PATH"
    export ARGV_LOG="$BASE_TMP/argv_i3.log"
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
    unset CODEGEN_CALL_AGENTS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/argv_i3_stderr.log" || true
)
assert_log_absent_line "$BASE_TMP/argv_i3.log" "--agents" "(i3) CODEGEN_CALL_AGENTS_PATH unset: --agents flag absent"

# (i4) CODEGEN_CALL_PRINT_ARGV=1 → argv printed to stdout, exit 0, claude never touched
PRINT_ARGV_MARKER="$BASE_TMP/print_argv_never_called"
rm -f "$PRINT_ARGV_MARKER"
NEVER_STUB_DIR="$BASE_TMP/never_stub_bin"
mkdir -p "$NEVER_STUB_DIR"
cat >"$NEVER_STUB_DIR/claude" <<NEVERSTUB
#!/usr/bin/env bash
touch "$PRINT_ARGV_MARKER"
cat "\$FIXTURE_PATH"
NEVERSTUB
chmod +x "$NEVER_STUB_DIR/claude"

I4_EXIT=0
I4_OUT_LOG="$BASE_TMP/argv_i4_stdout.log"
(
    export PATH="$NEVER_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_AGENT="developer-static"
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    export CODEGEN_CALL_PRINT_ARGV=1
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    unset CODEGEN_CALL_AGENTS_PATH 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >"$I4_OUT_LOG" 2>"$BASE_TMP/argv_i4_stderr.log"
) || I4_EXIT=$?

if [[ "$I4_EXIT" == "0" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (i4) --print-argv exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (i4) --print-argv exits 0 — got %s\n' "$I4_EXIT"
    fail=$((fail + 1))
fi
assert_log_contains_line "$I4_OUT_LOG" "claude-haiku-4-5" "(i4) --print-argv output mentions model"
assert_log_contains_line "$I4_OUT_LOG" "developer-static" "(i4) --print-argv output mentions agent"
if [[ -f "$PRINT_ARGV_MARKER" ]]; then
    printf 'FAIL: (i4) --print-argv must never exec claude\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

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

# ── Pi loop role identity: --agent resolution, AGENT_TYPE export, minted session id ──
PI_DISPATCH_SCRIPT="$(cd "$HOOKS_DIR/../../pi" && pwd)/call-dispatch.sh"

PI_STUB_DIR="$BASE_TMP/pi_stub_bin"
mkdir -p "$PI_STUB_DIR"
cat >"$PI_STUB_DIR/pi" <<'PISTUB'
#!/usr/bin/env bash
# Stub pi: log argv + AGENT_TYPE, emit fixture, exit 0
: >"$PI_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$PI_ARGV_LOG"; done
printf '%s\n' "${AGENT_TYPE:-}" >"$PI_AGENT_TYPE_SEEN"
cat "$PI_FIXTURE_PATH"
PISTUB
chmod +x "$PI_STUB_DIR/pi"

PI_FIXTURE="$BASE_TMP/pi_agent_end.jsonl"
cat >"$PI_FIXTURE" <<'PIFIX'
{"type":"agent_end","messages":[{"role":"assistant","content":"work complete"}],"usage":{"input_tokens":12,"output_tokens":4}}
PIFIX

PI_FAKE_HOME="$BASE_TMP/pi_fake_home"
mkdir -p "$PI_FAKE_HOME/.pi/agent/agents"
printf 'You are the committer agent.' >"$PI_FAKE_HOME/.pi/agent/agents/committer.md"

# (r) --agent set + agent file present → resolves prompt, exports AGENT_TYPE,
#     mints + echoes a session id, uses --system-prompt (REPLACE) not --append.
PI_R_EXIT=0
(
    export PATH="$PI_STUB_DIR:$PATH"
    export HOME="$PI_FAKE_HOME"
    export PI_ARGV_LOG="$BASE_TMP/pi_argv_r.log"
    export PI_AGENT_TYPE_SEEN="$BASE_TMP/pi_agent_type_r.txt"
    export PI_FIXTURE_PATH="$PI_FIXTURE"
    export CODEGEN_CALL_AGENT="committer"
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Commit the change."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" 2>"$BASE_TMP/pi_r_stderr.log"
) >"$BASE_TMP/pi_r_envelope.json" || PI_R_EXIT=$?

if [[ "$PI_R_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (r) pi --agent call exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (r) pi --agent call exits 0 — got %d\n  stderr: %s\n' "$PI_R_EXIT" "$(cat "$BASE_TMP/pi_r_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

assert_log_contains_line "$BASE_TMP/pi_argv_r.log" "--system-prompt" \
    "(r) --agent resolved: --system-prompt flag present"
assert_log_line_after "$BASE_TMP/pi_argv_r.log" "--system-prompt" "You are the committer agent." \
    "(r) --agent resolved: agent .md body used as system prompt"
assert_log_absent_line "$BASE_TMP/pi_argv_r.log" "--append-system-prompt" \
    "(r) --agent resolved: no --append-system-prompt (REPLACE contract)"

if [[ "$(cat "$BASE_TMP/pi_agent_type_r.txt" 2>/dev/null || true)" == "committer" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (r) AGENT_TYPE exported to pi process env\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (r) AGENT_TYPE not exported — got %q\n' "$(cat "$BASE_TMP/pi_agent_type_r.txt" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

R_ENVELOPE="$(cat "$BASE_TMP/pi_r_envelope.json")"
assert_jq_truthy "(r) envelope session_id non-null in agent mode" "$R_ENVELOPE" '.session_id != null'
assert_jq_truthy "(r) envelope session_id non-empty string" "$R_ENVELOPE" '(.session_id | type) == "string" and (.session_id | length) > 0'

# (s) --agent set but the agent .md is absent → exit 2, loud stderr, no silent fallback
PI_S_EXIT=0
(
    export PATH="$PI_STUB_DIR:$PATH"
    export HOME="$PI_FAKE_HOME"
    export PI_ARGV_LOG="$BASE_TMP/pi_argv_s.log"
    export PI_AGENT_TYPE_SEEN="$BASE_TMP/pi_agent_type_s.txt"
    export PI_FIXTURE_PATH="$PI_FIXTURE"
    export CODEGEN_CALL_AGENT="no-such-role"
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do the thing."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" 2>"$BASE_TMP/pi_s_stderr.log"
) >"$BASE_TMP/pi_s_envelope.json" || PI_S_EXIT=$?

if [[ "$PI_S_EXIT" -eq 2 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (s) missing agent definition exits 2\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (s) missing agent definition exits 2 — got %d\n' "$PI_S_EXIT"
    fail=$((fail + 1))
fi
assert_file_contains "$BASE_TMP/pi_s_stderr.log" "agent definition not found"

# (t) no --agent (bare one-shot) → session_id stays null, --no-session used
PI_T_EXIT=0
(
    export PATH="$PI_STUB_DIR:$PATH"
    export HOME="$PI_FAKE_HOME"
    export PI_ARGV_LOG="$BASE_TMP/pi_argv_t.log"
    export PI_AGENT_TYPE_SEEN="$BASE_TMP/pi_agent_type_t.txt"
    export PI_FIXTURE_PATH="$PI_FIXTURE"
    unset CODEGEN_CALL_AGENT 2>/dev/null || true
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a one-shot assistant."
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this."
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    # Bare one-shot mode must mint no session id (--no-session, null in the
    # envelope). Without this unset, an ambient CODEGEN_CALL_SESSION_ID
    # (e.g. this very test run invoked from inside a live codegen-call/
    # Claude session, which exports it — see codegen-call:353) leaks through
    # and this case spuriously fails outside a fully clean shell.
    unset CODEGEN_CALL_SESSION_ID 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" 2>"$BASE_TMP/pi_t_stderr.log"
) >"$BASE_TMP/pi_t_envelope.json" || PI_T_EXIT=$?

if [[ "$PI_T_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (t) bare one-shot pi call exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (t) bare one-shot pi call exits 0 — got %d\n' "$PI_T_EXIT"
    fail=$((fail + 1))
fi
assert_log_contains_line "$BASE_TMP/pi_argv_t.log" "--no-session" \
    "(t) bare one-shot: --no-session used (ephemeral)"
T_ENVELOPE="$(cat "$BASE_TMP/pi_t_envelope.json")"
assert_jq "(t) bare one-shot: envelope session_id is null" "$T_ENVELOPE" ".session_id" "null"

# (u) --resume set + --agent set → resumed id threaded verbatim, no minting
(
    export PATH="$PI_STUB_DIR:$PATH"
    export HOME="$PI_FAKE_HOME"
    export PI_ARGV_LOG="$BASE_TMP/pi_argv_u.log"
    export PI_AGENT_TYPE_SEEN="$BASE_TMP/pi_agent_type_u.txt"
    export PI_FIXTURE_PATH="$PI_FIXTURE"
    export CODEGEN_CALL_AGENT="committer"
    export CODEGEN_CALL_RESUME="warm-pi-session-999"
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Resume and commit."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" 2>"$BASE_TMP/pi_u_stderr.log"
) >"$BASE_TMP/pi_u_envelope.json" || true

U_ENVELOPE="$(cat "$BASE_TMP/pi_u_envelope.json")"
assert_jq "(u) --resume set: envelope session_id echoes resumed id" "$U_ENVELOPE" ".session_id" "warm-pi-session-999"
assert_log_line_after "$BASE_TMP/pi_argv_u.log" "--session-id" "warm-pi-session-999" \
    "(u) --resume set: --session-id carries the resumed id verbatim"

# (v) CODEGEN_CALL_AGENTS_PATH set on pi → accepted, ignored, never forwarded
PI_AGENTS_FIXTURE="$BASE_TMP/pi_agents_fixture.json"
printf '{"probe-agent":{"description":"probe","prompt":"probe","tools":[]}}' >"$PI_AGENTS_FIXTURE"
PI_V_EXIT=0
(
    export PATH="$PI_STUB_DIR:$PATH"
    export HOME="$PI_FAKE_HOME"
    export PI_ARGV_LOG="$BASE_TMP/pi_argv_v.log"
    export PI_AGENT_TYPE_SEEN="$BASE_TMP/pi_agent_type_v.txt"
    export PI_FIXTURE_PATH="$PI_FIXTURE"
    export CODEGEN_CALL_AGENT="committer"
    export CODEGEN_CALL_AGENTS_PATH="$PI_AGENTS_FIXTURE"
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Commit the change."
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" 2>"$BASE_TMP/pi_v_stderr.log"
) >"$BASE_TMP/pi_v_envelope.json" || PI_V_EXIT=$?

if [[ "$PI_V_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (v) pi call with CODEGEN_CALL_AGENTS_PATH set exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (v) pi call with CODEGEN_CALL_AGENTS_PATH set exits 0 — got %d\n' "$PI_V_EXIT"
    fail=$((fail + 1))
fi
assert_log_absent_line "$BASE_TMP/pi_argv_v.log" "--agents" \
    "(v) CODEGEN_CALL_AGENTS_PATH set: --agents never forwarded to pi (no native concept)"
assert_log_absent_line "$BASE_TMP/pi_argv_v.log" "probe-agent" \
    "(v) CODEGEN_CALL_AGENTS_PATH set: inline agent JSON content never forwarded to pi"

# (w) CODEGEN_CALL_PRINT_ARGV=1 on pi → argv printed to stdout, exit 0, pi never touched
PI_PRINT_MARKER="$BASE_TMP/pi_print_argv_never_called"
rm -f "$PI_PRINT_MARKER"
PI_NEVER_STUB_DIR="$BASE_TMP/pi_never_stub_bin"
mkdir -p "$PI_NEVER_STUB_DIR"
cat >"$PI_NEVER_STUB_DIR/pi" <<PINEVERSTUB
#!/usr/bin/env bash
touch "$PI_PRINT_MARKER"
cat "\$PI_FIXTURE_PATH"
PINEVERSTUB
chmod +x "$PI_NEVER_STUB_DIR/pi"

PI_W_EXIT=0
PI_W_OUT_LOG="$BASE_TMP/pi_argv_w_stdout.log"
(
    export PATH="$PI_NEVER_STUB_DIR:$PATH"
    export HOME="$PI_FAKE_HOME"
    export PI_FIXTURE_PATH="$PI_FIXTURE"
    export CODEGEN_CALL_AGENT="committer"
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Commit the change."
    export CODEGEN_CALL_PRINT_ARGV=1
    unset CODEGEN_CALL_SYSTEM_PROMPT 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_AGENTS_PATH 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" >"$PI_W_OUT_LOG" 2>"$BASE_TMP/pi_w_stderr.log"
) || PI_W_EXIT=$?

if [[ "$PI_W_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (w) pi --print-argv exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (w) pi --print-argv exits 0 — got %d\n' "$PI_W_EXIT"
    fail=$((fail + 1))
fi
assert_log_contains_line "$PI_W_OUT_LOG" "You are the committer agent." "(w) pi --print-argv output mentions system prompt content"
if [[ -f "$PI_PRINT_MARKER" ]]; then
    printf 'FAIL: (w) pi --print-argv must never exec pi\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# ── Watchdog: hang-after-emit salvage + mid-stream stall (CODEGEN_LOOP=1) ────
# Stub claude that emits the fixture then sleeps indefinitely (simulates a
# stalled ESTABLISHED socket after the process has already produced output).
WATCHDOG_STUB_DIR="$BASE_TMP/watchdog_stub_bin"
mkdir -p "$WATCHDOG_STUB_DIR"
cat >"$WATCHDOG_STUB_DIR/claude" <<'WDSTUB'
#!/usr/bin/env bash
# Stub claude: emit fixture (result event present), then hang forever.
cat "$FIXTURE_PATH"
sleep 3600
WDSTUB
chmod +x "$WATCHDOG_STUB_DIR/claude"

# Stub claude that hangs with NO output at all (mid-stream stall, nothing to salvage).
WATCHDOG_STALL_STUB_DIR="$BASE_TMP/watchdog_stall_stub_bin"
mkdir -p "$WATCHDOG_STALL_STUB_DIR"
cat >"$WATCHDOG_STALL_STUB_DIR/claude" <<'WDSTALLSTUB'
#!/usr/bin/env bash
# Stub claude: no output, hang forever.
sleep 3600
WDSTALLSTUB
chmod +x "$WATCHDOG_STALL_STUB_DIR/claude"

# (x) Hang-after-emit: result event present, process never exits → watchdog
# kills after RESULT_GRACE_SECS, salvages the already-emitted result as success.
WD_X_EXIT=0
WD_X_START=$(date +%s)
(
    export PATH="$WATCHDOG_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=2
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
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

assert_file_contains "$BASE_TMP/wd_x_stderr.log" "watchdog killing claude"

if [[ "$WD_X_ELAPSED" -lt 60 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (x) watchdog recovers in well under idle cap (%ds)\n' "$WD_X_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (x) watchdog took too long to recover (%ds)\n' "$WD_X_ELAPSED"
    fail=$((fail + 1))
fi

# (y) Mid-stream stall: no output at all → watchdog idle-caps, emits failed
# envelope with retryable "Stream idle timeout" reason, exits 0 (not 1) so the
# loop reads the full untruncated reason.
WD_Y_EXIT=0
(
    export PATH="$WATCHDOG_STALL_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=2
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
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

assert_file_contains "$BASE_TMP/wd_y_stderr.log" "watchdog killing claude"

# (z) Loop-gate off (no CODEGEN_LOOP): watchdog never engages — one-shot
# platform codegen-call behavior stays byte-identical (uncapped). Uses a
# short-lived stub (not the hanging one) since an unbounded exec would hang
# this test suite itself.
WD_Z_EXIT=0
(
    export PATH="$STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_CALL_JSON_SCHEMA='{"type":"object","properties":{"lang":{"type":"string"},"intent":{"type":"string"}},"required":["lang","intent"]}'
    unset CODEGEN_LOOP 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
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

assert_log_absent_line "$BASE_TMP/wd_z_stderr.log" "watchdog killing claude" \
    "(z) loop-gate off: watchdog never engages"

# ── Tool-trace metrics envelope block (real probed stream-json fixtures) ─────
FIXTURE_TOOL_TRACE="$HOOKS_DIR/fixtures/tool_trace.jsonl"
FIXTURE_TOOL_TRACE_SUBAGENT="$HOOKS_DIR/fixtures/tool_trace_subagent.jsonl"
PI_FIXTURE_TOOL_TRACE="$HOOKS_DIR/fixtures/pi_tool_trace.jsonl"

# (m) tool_trace fixture: literal count constants (read/write/bash == 1 each)
(
    export FIXTURE_PATH="$FIXTURE_TOOL_TRACE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do file work."
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/metrics_m_envelope.json" 2>/dev/null || true
M_ENVELOPE="$(cat "$BASE_TMP/metrics_m_envelope.json")"

assert_jq "(m) metrics.read_count == 1" "$M_ENVELOPE" ".metrics.read_count" "1"
assert_jq "(m) metrics.write_count == 1" "$M_ENVELOPE" ".metrics.write_count" "1"
assert_jq "(m) metrics.bash_count == 1" "$M_ENVELOPE" ".metrics.bash_count" "1"

# (n) tool_trace fixture: tool_counts.Read == 1
assert_jq "(n) metrics.tool_counts.Read == 1" "$M_ENVELOPE" ".metrics.tool_counts.Read" "1"

# (o) tool_trace fixture: stop_reason + rate_limited present (real result/rate_limit_event)
assert_jq "(o) metrics.stop_reason == end_turn" "$M_ENVELOPE" ".metrics.stop_reason" "end_turn"
assert_jq "(o) metrics.rate_limited == false" "$M_ENVELOPE" ".metrics.rate_limited" "false"

# (p) subagent fixture: per_subagent join via parent_tool_use_id -> Agent.input.subagent_type
(
    export FIXTURE_PATH="$FIXTURE_TOOL_TRACE_SUBAGENT"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Spawn a subagent."
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/metrics_p_envelope.json" 2>/dev/null || true
P_ENVELOPE="$(cat "$BASE_TMP/metrics_p_envelope.json")"

assert_jq "(p) per_subagent[general-purpose].bash_count == 1" "$P_ENVELOPE" \
    '.metrics.per_subagent["general-purpose"].bash_count' "1"

# (q) is_error fixture: metrics absent entirely (no faked zeros on a failure path)
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
) >"$BASE_TMP/metrics_q_envelope.json" 2>/dev/null || true
Q_ENVELOPE="$(cat "$BASE_TMP/metrics_q_envelope.json")"

assert_jq "(q) failure envelope: metrics key absent" "$Q_ENVELOPE" 'has("metrics")' "false"

# (r) old text-only fixture (question_mark_reply, no tool events): still exits
# 0, result.status == success — additive key breaks no existing back-compat path.
(
    export FIXTURE_PATH="$FIXTURE_QMARK"
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
) >"$BASE_TMP/metrics_r_envelope.json" 2>/dev/null || true
R_ENVELOPE="$(cat "$BASE_TMP/metrics_r_envelope.json")"

assert_jq "(r) back-compat: result.status still success" "$R_ENVELOPE" ".result.status" "success"

# (s) pi fixture: metrics.read_count == 1; rate_limited/per_subagent OMITTED
# (pi's event vocabulary cannot supply them — omission, not faking).
PI_METRICS_STUB_DIR="$BASE_TMP/pi_metrics_stub_bin"
mkdir -p "$PI_METRICS_STUB_DIR"
cat >"$PI_METRICS_STUB_DIR/pi" <<'PIMETRICSSTUB'
#!/usr/bin/env bash
cat "$PI_FIXTURE_PATH"
PIMETRICSSTUB
chmod +x "$PI_METRICS_STUB_DIR/pi"

(
    export PATH="$PI_METRICS_STUB_DIR:$PATH"
    export PI_FIXTURE_PATH="$PI_FIXTURE_TOOL_TRACE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
    export CODEGEN_CALL_MODEL="gpt-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Do file work."
    unset CODEGEN_CALL_AGENT 2>/dev/null || true
    unset CODEGEN_CALL_RESUME 2>/dev/null || true
    unset CODEGEN_CALL_EXTENSION_PATH 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_SESSION_ID 2>/dev/null || true
    bash "$PI_DISPATCH_SCRIPT" 2>/dev/null
) >"$BASE_TMP/metrics_s_envelope.json" 2>/dev/null || true
S_ENVELOPE="$(cat "$BASE_TMP/metrics_s_envelope.json")"

assert_jq "(s) pi metrics.read_count == 1" "$S_ENVELOPE" ".metrics.read_count" "1"
assert_jq "(s) pi metrics.rate_limited omitted (not faked)" "$S_ENVELOPE" 'has("rate_limited")' "false"
assert_jq "(s) pi metrics has(\"rate_limited\") within metrics also absent" "$S_ENVELOPE" '.metrics | has("rate_limited")' "false"
assert_jq "(s) pi metrics.per_subagent omitted" "$S_ENVELOPE" '.metrics | has("per_subagent")' "false"

# (t) RED-then-GREEN: synthetic pre-fix builder (no metrics summarization) —
# proves assertion (m) is load-bearing, not a vacuous grep. Mirrors the
# RED-then-GREEN idiom used above for FIX-1/FIX-3 (case g).
PRE_METRICS_SCRIPT="$BASE_TMP/call-dispatch.pre-metrics.sh"
cat >"$PRE_METRICS_SCRIPT" <<'PREMETRICS'
#!/usr/bin/env bash
# Synthetic reproduction of the pre-fix envelope: no metrics block at all,
# regardless of tool events present in the source stream.
set -euo pipefail
jq -n '{
    result: {status: "success", value: "ok", reason: null, retry_meta: null},
    usage: {input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0, cost_usd: 0, latency_ms: 0, model: "test", num_turns: 1},
    error: null,
    harness: "claude_code",
    session_id: null
}'
PREMETRICS
chmod +x "$PRE_METRICS_SCRIPT"

PRE_METRICS_ENVELOPE="$(bash "$PRE_METRICS_SCRIPT")"
PRE_METRICS_READ_COUNT="$(printf '%s' "$PRE_METRICS_ENVELOPE" | jq -r '.metrics.read_count // "MISSING"')"
if [[ "$PRE_METRICS_READ_COUNT" == "MISSING" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: RED-then-GREEN — pre-fix envelope fails the (m) metrics.read_count assertion as expected\n'
    pass=$((pass + 1))
else
    printf 'FAIL: RED-then-GREEN — pre-fix envelope unexpectedly satisfies the (m) metrics assertion (got %q)\n' "$PRE_METRICS_READ_COUNT"
    fail=$((fail + 1))
fi
rm -f "$PRE_METRICS_SCRIPT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
