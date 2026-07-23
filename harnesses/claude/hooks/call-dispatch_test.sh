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

# shellcheck source=/dev/null
source "$HOOKS_DIR/../../shared/test-stub-lib.sh"

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

assert_path_absent() {
    local filepath="$1" desc="$2"
    if [[ ! -e "$filepath" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — unexpected path exists: %s\n' "$desc" "$filepath"
        fail=$((fail + 1))
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
cat >"$STUB_DIR/claude.body" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub claude: ignore all args, emit fixture to stdout, exit 0
exec cat "$FIXTURE_PATH"
STUB_EOF
link_stub_path "$STUB_DIR/claude"

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

# ── usage fields lifted from the result event (num_turns/cost already present;
#    duration_ms/duration_api_ms/ttft_ms/permission_denials/stop_reason are new
#    — see pitch "build-cycle-accounts-for-its-own-time" Move 2) ─────────────

# num_turns/cost_usd present on this fixture's result event → lifted, not null
assert_jq "usage.num_turns lifted from result event" "$ENVELOPE" ".usage.num_turns" "2"
assert_jq "usage.cost_usd lifted from result event" "$ENVELOPE" ".usage.cost_usd" "0.001"

# duration_ms/duration_api_ms/ttft_ms/permission_denials/stop_reason are ABSENT
# on this fixture's result event → must record JSON null, never a fabricated 0
assert_jq "usage.duration_ms is null when absent from result event (not 0)" \
    "$ENVELOPE" ".usage.duration_ms" "null"
assert_jq "usage.duration_api_ms is null when absent from result event (not 0)" \
    "$ENVELOPE" ".usage.duration_api_ms" "null"
assert_jq "usage.ttft_ms is null when absent from result event (not 0)" \
    "$ENVELOPE" ".usage.ttft_ms" "null"
assert_jq "usage.permission_denials is null when absent from result event (not 0)" \
    "$ENVELOPE" ".usage.permission_denials" "null"
assert_jq "usage.stop_reason is null when absent from result event" \
    "$ENVELOPE" ".usage.stop_reason" "null"

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

# ── MCP wiring: --mcp-config added, --strict-mcp-config retained ────────────
# strict-mcp-config walls out tidewave/chrome/anything else; --mcp-config
# names ONLY the codegen server (when its dist/ has been built).
assert_file_contains "$HARNESSES_DIR/call-dispatch.sh" "--strict-mcp-config"
assert_file_contains "$HARNESSES_DIR/call-dispatch.sh" "--mcp-config"
assert_file_contains "$HARNESSES_DIR/call-dispatch.sh" "MCP_SERVER_DIST"

# Functional: --print-argv omits --mcp-config when the server isn't built
# (OCG_CODEGEN_DIR points at an empty scratch dir, so mcp-server/dist/index.js
# does not exist there — the dispatcher must not fail, just omit the flag).
MCP_SCRATCH_DIR="$(mktemp -d)"
mkdir -p "$MCP_SCRATCH_DIR/harnesses/claude"
MCP_ARGV_NO_SERVER="$(
    CODEGEN_CALL_MODEL="test-model" CODEGEN_CALL_EFFORT="low" \
        CODEGEN_CALL_PROMPT="hi" CODEGEN_CALL_SYSTEM_PROMPT="sp" \
        CODEGEN_CALL_PRINT_ARGV="1" OCG_CODEGEN_DIR="$MCP_SCRATCH_DIR" \
        bash "$DISPATCH_SCRIPT" 2>&1
)"
if printf '%s' "$MCP_ARGV_NO_SERVER" | grep -q -- "--mcp-config"; then
    printf 'FAIL: --print-argv includes --mcp-config when mcp-server/dist is absent\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: --print-argv omits --mcp-config when mcp-server/dist is absent\n'
    pass=$((pass + 1))
fi
if printf '%s' "$MCP_ARGV_NO_SERVER" | grep -q -- "--strict-mcp-config"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: --print-argv retains --strict-mcp-config regardless of server build state\n'
    pass=$((pass + 1))
else
    printf 'FAIL: --print-argv missing --strict-mcp-config\n'
    fail=$((fail + 1))
fi
rm -rf "$MCP_SCRATCH_DIR"

# Test 5-7: mode-thinking-parity_test.sh now owns per-mode MAX_THINKING_TOKENS
# declaration/consumption policy (declared roles.<mode>.thinking_tokens, both
# interactive+headless branches, no hard-coded positive literal). This file
# keeps only the global-zero (call-dispatch.sh, installed settings) contract.

# Test 8-11: interactive launchers carry CLAUDE_AFK_TIMEOUT_MS
assert_file_contains "$HARNESSES_DIR/claude-shape.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-debug.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-experiment.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-ops.sh" "CLAUDE_AFK_TIMEOUT_MS"
assert_file_contains "$HARNESSES_DIR/claude-babysit.sh" "CLAUDE_AFK_TIMEOUT_MS"

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
cat >"$ARGV_STUB_DIR/claude.body" <<'ARGVSTUB'
#!/usr/bin/env bash
# Log every arg on its own line, then emit the fixture (no exec — statements after must run)
: >"$ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$ARGV_LOG"; done
cat "$FIXTURE_PATH"
ARGVSTUB
link_stub_path "$ARGV_STUB_DIR/claude"

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
cat >"$NEVER_STUB_DIR/claude.body" <<NEVERSTUB
#!/usr/bin/env bash
touch "$PRINT_ARGV_MARKER"
cat "\$FIXTURE_PATH"
NEVERSTUB
link_stub_path "$NEVER_STUB_DIR/claude"

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
cat >"$PI_STUB_DIR/pi.body" <<'PISTUB'
#!/usr/bin/env bash
# Stub pi: log argv + AGENT_TYPE, emit fixture, exit 0
: >"$PI_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$PI_ARGV_LOG"; done
printf '%s\n' "${AGENT_TYPE:-}" >"$PI_AGENT_TYPE_SEEN"
cat "$PI_FIXTURE_PATH"
PISTUB
link_stub_path "$PI_STUB_DIR/pi"

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
cat >"$PI_NEVER_STUB_DIR/pi.body" <<PINEVERSTUB
#!/usr/bin/env bash
touch "$PI_PRINT_MARKER"
cat "\$PI_FIXTURE_PATH"
PINEVERSTUB
link_stub_path "$PI_NEVER_STUB_DIR/pi"

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
cat >"$WATCHDOG_STUB_DIR/claude.body" <<'WDSTUB'
#!/usr/bin/env bash
# Stub claude: emit fixture (result event present), then hang forever.
cat "$FIXTURE_PATH"
sleep 3600
WDSTUB
link_stub_path "$WATCHDOG_STUB_DIR/claude"

# Stub claude that hangs with NO output at all (mid-stream stall, nothing to salvage).
WATCHDOG_STALL_STUB_DIR="$BASE_TMP/watchdog_stall_stub_bin"
mkdir -p "$WATCHDOG_STALL_STUB_DIR"
cat >"$WATCHDOG_STALL_STUB_DIR/claude.body" <<'WDSTALLSTUB'
#!/usr/bin/env bash
# Stub claude: no output, hang forever. Exec keeps the stub itself as the
# group leader, matching the real Claude binary (no synthetic shell child).
exec sleep 3600
WDSTALLSTUB
link_stub_path "$WATCHDOG_STALL_STUB_DIR/claude"

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
    export CODEGEN_CALL_POLL_SECS=0.5
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
    export CODEGEN_CALL_POLL_SECS=0.5
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

# ── Watchdog: dead-stream cap (Trigger 3, CODEGEN_CALL_STREAM_IDLE_SECS) ─────
# Keep a PATH-isolated stub directory for the watchdog process fixtures.
PGREP_STUB_DIR="$BASE_TMP/pgrep_stub_bin"
mkdir -p "$PGREP_STUB_DIR"

# (aa) Dead stream: no output growth AND no live tool subprocess (pgrep empty)
# → killed after STREAM_IDLE_SECS with the "stream idle" reason.
cat >"$PGREP_STUB_DIR/pgrep.body" <<'PGREPEMPTY'
#!/usr/bin/env bash
# Always report no children — simulates a dead socket with no tool running.
exit 1
PGREPEMPTY
link_stub_path "$PGREP_STUB_DIR/pgrep"
link_or_copy "$WATCHDOG_STALL_STUB_DIR/claude" "$PGREP_STUB_DIR/claude"
link_or_copy "$WATCHDOG_STALL_STUB_DIR/claude.body" "$PGREP_STUB_DIR/claude.body"

WD_AA_EXIT=0
WD_AA_START=$(date +%s)
(
    export PATH="$PGREP_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_STREAM_IDLE_SECS=2
    export CODEGEN_CALL_POLL_SECS=0.5
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_aa_stderr.log"
) >"$BASE_TMP/wd_aa_envelope.json" || WD_AA_EXIT=$?
WD_AA_ELAPSED=$(($(date +%s) - WD_AA_START))

if [[ "$WD_AA_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (aa) dead-stream cap: dispatch exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (aa) dead-stream cap: dispatch exits 0 — got %d\n' "$WD_AA_EXIT"
    fail=$((fail + 1))
fi

assert_file_contains "$BASE_TMP/wd_aa_stderr.log" "stream idle"

if [[ "$WD_AA_ELAPSED" -lt 60 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (aa) dead-stream cap fires well under the 900s idle backstop (%ds)\n' "$WD_AA_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (aa) dead-stream cap took too long (%ds)\n' "$WD_AA_ELAPSED"
    fail=$((fail + 1))
fi

# (bb) Live-but-quiet: no output growth BUT a tool subprocess IS running → the
# short dead-stream cap must NOT fire; only the longer idle backstop governs.
cat >"$PGREP_STUB_DIR/pgrep_real.body" <<'PGREPREAL'
#!/usr/bin/env bash
exec /usr/bin/pgrep "$@"
PGREPREAL
link_stub_path "$PGREP_STUB_DIR/pgrep_real"
_warm_replace "$PGREP_STUB_DIR/claude" "$(
    cat <<'WDLIVESTUB'
#!/usr/bin/env bash
# Stub claude: spawn a long-lived child (simulates a bash tool subprocess
# still running), emit no output itself, then hang.
sleep 3600 &
wait
WDLIVESTUB
)"
# Use the REAL pgrep for this case (need it to actually see the spawned child).
_warm_replace "$PGREP_STUB_DIR/pgrep" "$(cat "$PGREP_STUB_DIR/pgrep_real.body")"

WD_BB_EXIT=0
WD_BB_START=$(date +%s)
(
    export PATH="$PGREP_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=3
    export CODEGEN_CALL_STREAM_IDLE_SECS=2
    export CODEGEN_CALL_POLL_SECS=0.5
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_bb_stderr.log"
) >"$BASE_TMP/wd_bb_envelope.json" || WD_BB_EXIT=$?
WD_BB_ELAPSED=$(($(date +%s) - WD_BB_START))

assert_log_absent_line "$BASE_TMP/wd_bb_stderr.log" "stream idle" \
    "(bb) live-but-quiet (tool subprocess running): short dead-stream cap must not fire"

assert_file_contains "$BASE_TMP/wd_bb_stderr.log" "idle 3s with no output growth"

if [[ "$WD_BB_ELAPSED" -ge 3 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (bb) live-but-quiet: governed by the longer idle backstop (%ds), not the short cap\n' "$WD_BB_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (bb) live-but-quiet: killed too early (%ds) — short cap fired despite live subprocess\n' "$WD_BB_ELAPSED"
    fail=$((fail + 1))
fi

# (bb2) The direct tool parent can exit before its work. Leave only its
# reparented grandchild in Claude's PGID; a direct-child probe misses it, while
# the PGID-wide detector must keep suppressing the short stream-idle cap.
ORPHAN_HELPER="$BASE_TMP/orphan_tool_helper.sh"
cat >"$ORPHAN_HELPER" <<'ORPHANHELPER'
#!/usr/bin/env bash
sleep 3600 </dev/null >/dev/null 2>&1 &
exit 0
ORPHANHELPER
chmod +x "$ORPHAN_HELPER"
_warm_replace "$PGREP_STUB_DIR/claude" "$(
    cat <<ORPHANSTUB
#!/usr/bin/env bash
"$ORPHAN_HELPER"
exec sleep 3600
ORPHANSTUB
)"

WD_BB2_START=$(date +%s)
(
    export PATH="$PGREP_STUB_DIR:$PATH"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5" CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message"
    export CODEGEN_LOOP=1 CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=3 CODEGEN_CALL_STREAM_IDLE_SECS=2 CODEGEN_CALL_POLL_SECS=0.5
    unset CODEGEN_CALL_JSON_SCHEMA CODEGEN_CALL_JSON_SCHEMA_PATH CODEGEN_CALL_ALLOWED_TOOLS_SET \
        CODEGEN_CALL_ALLOWED_TOOLS CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_bb2_stderr.log"
) >"$BASE_TMP/wd_bb2_envelope.json" || true
WD_BB2_ELAPSED=$(($(date +%s) - WD_BB2_START))

assert_log_absent_line "$BASE_TMP/wd_bb2_stderr.log" "stream idle" \
    "(bb2) reparented non-MCP grandchild in Claude PGID suppresses short cap"
assert_file_contains "$BASE_TMP/wd_bb2_stderr.log" "idle 3s with no output growth"
if [[ "$WD_BB2_ELAPSED" -ge 3 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (bb2) reparented grandchild governed by idle backstop (%ds)\n' "$WD_BB2_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (bb2) reparented grandchild was killed by short cap (%ds)\n' "$WD_BB2_ELAPSED"
    fail=$((fail + 1))
fi

# (bc) Claude MCP server child is always present, but it is not tool work.
# A stalled role with only that child must still hit the short dead-stream cap.
MCP_CHILD="$BASE_TMP/harnesses/claude/mcp-server/dist/index.js"
mkdir -p "$(dirname "$MCP_CHILD")"
cat >"$MCP_CHILD" <<'MCPCHILD'
#!/usr/bin/env bash
sleep 3600
MCPCHILD
chmod +x "$MCP_CHILD"
_warm_replace "$PGREP_STUB_DIR/claude" "$(
    cat <<WDMCPSTUB
#!/usr/bin/env bash
"$MCP_CHILD" &
wait
WDMCPSTUB
)"

WD_BC_EXIT=0
WD_BC_START=$(date +%s)
(
    export PATH="$PGREP_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE"
    export CODEGEN_CALL_SYSTEM_PROMPT="You are a test classifier assistant."
    export CODEGEN_CALL_MODEL="claude-haiku-4-5"
    export CODEGEN_CALL_EFFORT="low"
    export CODEGEN_CALL_PROMPT="Classify this message: Hello, how do I set up the platform?"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_STREAM_IDLE_SECS=2
    export CODEGEN_CALL_POLL_SECS=0.5
    unset CODEGEN_CALL_JSON_SCHEMA 2>/dev/null || true
    unset CODEGEN_CALL_JSON_SCHEMA_PATH 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
    unset CODEGEN_CALL_ALLOWED_TOOLS 2>/dev/null || true
    unset CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" 2>"$BASE_TMP/wd_bc_stderr.log"
) >"$BASE_TMP/wd_bc_envelope.json" || WD_BC_EXIT=$?
WD_BC_ELAPSED=$(($(date +%s) - WD_BC_START))

if [[ "$WD_BC_EXIT" -eq 0 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (bc) mcp-only child: dispatch exits 0\n'
    pass=$((pass + 1))
else
    printf 'FAIL: (bc) mcp-only child: dispatch exits 0 — got %d\n' "$WD_BC_EXIT"
    fail=$((fail + 1))
fi

assert_file_contains "$BASE_TMP/wd_bc_stderr.log" "stream idle"

if [[ "$WD_BC_ELAPSED" -lt 60 ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: (bc) mcp-only child: short cap still fires (%ds)\n' "$WD_BC_ELAPSED"
    pass=$((pass + 1))
else
    printf 'FAIL: (bc) mcp-only child: took too long (%ds)\n' "$WD_BC_ELAPSED"
    fail=$((fail + 1))
fi

# (bd) A successful Claude root may exit while a tool grandchild remains.
# The dispatcher must not return and leave that process able to mutate later.
TREE_STUB_DIR="$BASE_TMP/tree_stub_bin"
mkdir -p "$TREE_STUB_DIR"
cat >"$TREE_STUB_DIR/claude.body" <<'TREESTUB'
#!/usr/bin/env bash
(
    (sleep 2; printf 'late mutation\n' >"$TREE_MUTATION_PATH") </dev/null >/dev/null 2>&1 &
    wait
) </dev/null >/dev/null 2>&1 &
sleep 0.5
cat "$FIXTURE_PATH"
TREESTUB
link_stub_path "$TREE_STUB_DIR/claude"

(
    export PATH="$TREE_STUB_DIR:$PATH" TREE_MUTATION_PATH="$BASE_TMP/post_return_mutation"
    export CODEGEN_LOOP=1 CODEGEN_CALL_TERM_GRACE_SECS=0.1 CODEGEN_CALL_GUARD_POLL_SECS=0.05
    export CODEGEN_CALL_RESULT_GRACE_SECS=30 CODEGEN_CALL_IDLE_CAP_SECS=30 CODEGEN_CALL_POLL_SECS=0.1
    unset CODEGEN_CALL_JSON_SCHEMA CODEGEN_CALL_JSON_SCHEMA_PATH CODEGEN_CALL_ALLOWED_TOOLS_SET \
        CODEGEN_CALL_ALLOWED_TOOLS CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/tree_return_stderr.log"
)
sleep 3
assert_path_absent "$BASE_TMP/post_return_mutation" \
    "(bd) successful return cleans child and grandchild before late mutation"

# (be) SIGKILL cannot run the dispatcher's traps. Its independent guardian
# must still clean the recorded Claude tree after the owner disappears.
(
    export PATH="$TREE_STUB_DIR:$PATH" TREE_MUTATION_PATH="$BASE_TMP/post_kill_mutation"
    export CODEGEN_LOOP=1 CODEGEN_CALL_TERM_GRACE_SECS=0.1 CODEGEN_CALL_GUARD_POLL_SECS=0.05
    export CODEGEN_CALL_RESULT_GRACE_SECS=30 CODEGEN_CALL_IDLE_CAP_SECS=30 CODEGEN_CALL_POLL_SECS=0.1
    unset CODEGEN_CALL_JSON_SCHEMA CODEGEN_CALL_JSON_SCHEMA_PATH CODEGEN_CALL_ALLOWED_TOOLS_SET \
        CODEGEN_CALL_ALLOWED_TOOLS CODEGEN_CALL_SETTINGS_PATH 2>/dev/null || true
    exec bash "$DISPATCH_SCRIPT"
) >/dev/null 2>"$BASE_TMP/tree_kill_stderr.log" &
TREE_DISPATCH_PID=$!
sleep 0.8
kill -KILL "$TREE_DISPATCH_PID" 2>/dev/null || true
wait "$TREE_DISPATCH_PID" 2>/dev/null || true
sleep 3
assert_path_absent "$BASE_TMP/post_kill_mutation" \
    "(be) guardian cleans child and grandchild after dispatcher SIGKILL"

# (bf) Real cycle teardown targets the dispatcher's process group. Launch the
# dispatcher as a session leader, then kill that whole group; the guardian is
# in a different session and must still prevent the delayed grandchild write.
cat >"$TREE_STUB_DIR/claude.body" <<'TREEHANG'
#!/usr/bin/env bash
(
    (sleep 2; printf 'late mutation\n' >"$TREE_MUTATION_PATH") </dev/null >/dev/null 2>&1 &
    wait
) </dev/null >/dev/null 2>&1 &
sleep 3600
TREEHANG
TREE_DISPATCH_PID_FILE="$BASE_TMP/tree_dispatch.pgid"
(
    export PATH="$TREE_STUB_DIR:$PATH" TREE_MUTATION_PATH="$BASE_TMP/post_group_kill_mutation"
    export CODEGEN_LOOP=1 CODEGEN_CALL_TERM_GRACE_SECS=0.1 CODEGEN_CALL_GUARD_POLL_SECS=0.05
    export CODEGEN_CALL_IDLE_CAP_SECS=30 CODEGEN_CALL_POLL_SECS=0.1
    perl -MPOSIX -e '
        ($pidfile, @cmd) = @ARGV; $pid = fork(); exit 0 if $pid;
        POSIX::setsid(); open(my $fh, ">", $pidfile); print $fh "$$\n"; close($fh); exec @cmd;
    ' "$TREE_DISPATCH_PID_FILE" bash "$DISPATCH_SCRIPT"
)
sleep 0.8
TREE_DISPATCH_PGID="$(cat "$TREE_DISPATCH_PID_FILE")"
kill -KILL -- "-$TREE_DISPATCH_PGID" 2>/dev/null || true
sleep 3
assert_path_absent "$BASE_TMP/post_group_kill_mutation" \
    "(bf) isolated guardian survives dispatcher PGID death and cleans descendants"

# (bg) The BEAM owner PID is an independent lifecycle boundary. Killing it
# must tear down Claude even while the dispatcher itself remains alive.
sleep 3600 &
FAKE_BEAM_OWNER=$!
(
    export PATH="$TREE_STUB_DIR:$PATH" TREE_MUTATION_PATH="$BASE_TMP/post_owner_kill_mutation"
    export CODEGEN_LOOP=1 CODEGEN_CALL_OWNER_OS_PID="$FAKE_BEAM_OWNER"
    export CODEGEN_CALL_TERM_GRACE_SECS=0.1 CODEGEN_CALL_GUARD_POLL_SECS=0.05
    export CODEGEN_CALL_IDLE_CAP_SECS=30 CODEGEN_CALL_POLL_SECS=0.1
    bash "$DISPATCH_SCRIPT" >/dev/null 2>"$BASE_TMP/tree_owner_stderr.log"
) &
OWNER_DISPATCH_PID=$!
sleep 0.8
kill -TERM "$FAKE_BEAM_OWNER" 2>/dev/null || true
wait "$FAKE_BEAM_OWNER" 2>/dev/null || true
wait "$OWNER_DISPATCH_PID" 2>/dev/null || true
sleep 3
assert_path_absent "$BASE_TMP/post_owner_kill_mutation" \
    "(bg) BEAM owner death cleans Claude descendants before delayed mutation"

# (cc) default: CODEGEN_CALL_STREAM_IDLE_SECS unset → defaults to 300.
assert_file_contains "$DISPATCH_SCRIPT" \
    'STREAM_IDLE_SECS="${CODEGEN_CALL_STREAM_IDLE_SECS:-300}"'

# (dd) default: CODEGEN_CALL_POLL_SECS unset → defaults to 5 (production cadence unchanged).
assert_file_contains "$DISPATCH_SCRIPT" \
    'POLL_SECS="${CODEGEN_CALL_POLL_SECS:-5}"'

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

# (o2) tool_trace fixture: usage.duration_ms/duration_api_ms/ttft_ms/stop_reason
# lifted from the result event when present (pitch
# "build-cycle-accounts-for-its-own-time" Move 2)
assert_jq "(o2) usage.duration_ms lifted from result event" "$M_ENVELOPE" ".usage.duration_ms" "6712"
assert_jq "(o2) usage.duration_api_ms lifted from result event" "$M_ENVELOPE" ".usage.duration_api_ms" "8068"
assert_jq "(o2) usage.ttft_ms lifted from result event" "$M_ENVELOPE" ".usage.ttft_ms" "2295"
assert_jq "(o2) usage.stop_reason lifted from result event" "$M_ENVELOPE" ".usage.stop_reason" "end_turn"
# permission_denials: [] on this fixture -> length 0, not null (empty array is
# a known value, distinct from an absent key)
assert_jq "(o2) usage.permission_denials counts an empty array as 0, not null" \
    "$M_ENVELOPE" ".usage.permission_denials" "0"

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
cat >"$PI_METRICS_STUB_DIR/pi.body" <<'PIMETRICSSTUB'
#!/usr/bin/env bash
cat "$PI_FIXTURE_PATH"
PIMETRICSSTUB
link_stub_path "$PI_METRICS_STUB_DIR/pi"

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
