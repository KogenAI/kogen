#!/usr/bin/env bash
# codegen-call_test.sh — unit tests for codegen-call + call-dispatch.sh (claude + pi).
#
# Tests use stub harnesses (PATH-override bash scripts) so no real claude/pi calls.
#
# (a) --version prints version and exits 0
# (b) missing --harness exits 2 with usage on stderr
# (c) missing --model / --effort / --system-prompt / PROMPT each exits 2
# (d) invalid --harness=foo exits 2
# (e) missing @<path> for --system-prompt exits 2
# (f) claude_code success fixture: result.status==success, harness==claude_code, usage.input_tokens>0
# (g) claude_code schema-retry-exhausted fixture: result.status==schema_retry_exhausted, retry_meta populated
# (h) claude_code with --json-schema returning structured JSON: result.value is object
# (i) pi success fixture (agent_end with assistant text): result.status==success, harness==pi
# (j) pi empty reply: result.status==failed
# (l) exit codes: success→0; harness exits non-zero→codegen-call exits 1, error-envelope on stdout
# (m) envelope JSON validates against contract (all required keys present, types correct)
# (o) codegen-call source contains zero role-name tokens (planner/developer/committer/reviewer/curator)
# (p) codegen-call source contains zero --append-system-prompt tokens (REPLACE-only identity)
# (q) --agents value missing @ prefix exits 2
# (r) --agents @<nonexistent-path> exits 2
# (s2) --agents @<path> passed through to claude dispatch verbatim (real dispatch, stubbed claude)
# (t2) --print-argv on claude leg: prints argv, exits 0, never execs claude
# (u) usage string mentions every parsed flag; every usage-mentioned flag is parsed (parity)
# (snap) public flag surface snapshot: parsed flags == committed fixture (stability, distinct from parity)

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
CODEGEN_CALL="$CODEGEN_ROOT/codegen-call"
REAL_CLAUDE_HARNESS="$CODEGEN_ROOT/harnesses/claude"
REAL_PI_HARNESS="$CODEGEN_ROOT/harnesses/pi"

pass=0
fail=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:400}"
        fail=$((fail + 1))
    fi
}

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

make_stub() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

# Helper: create an isolated codegen-call root with call-dispatch stubs
# Strategy: copy codegen-call to a dir, create harnesses/ subdir with call-dispatch.sh
make_cc_root() {
    local name="$1"
    local dir="$BASE_TMP/$name"
    mkdir -p "$dir"
    cp "$CODEGEN_CALL" "$dir/codegen-call"
    chmod +x "$dir/codegen-call"
    echo "$dir"
}

# Write a stub claude call-dispatch.sh that emits a fixture envelope
make_claude_dispatch_stub() {
    local cc_root="$1"
    local body="$2"
    local harness_dir="$cc_root/harnesses/claude"
    mkdir -p "$harness_dir"
    make_stub "$harness_dir/call-dispatch.sh" "$body"
}

make_pi_dispatch_stub() {
    local cc_root="$1"
    local body="$2"
    local harness_dir="$cc_root/harnesses/pi"
    mkdir -p "$harness_dir"
    make_stub "$harness_dir/call-dispatch.sh" "$body"
}

# Create a tmp system-prompt file
SP_FILE="$BASE_TMP/system_prompt.txt"
printf 'You are a test assistant.' >"$SP_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Test (a): --version prints version string and exits 0
# ─────────────────────────────────────────────────────────────────────────────
CC_A="$(make_cc_root cc_a)"
actual_exit=0
VERSION_OUT="$("$CC_A/codegen-call" --version 2>/dev/null)" || actual_exit=$?
check "(a) --version exits 0" "0" "$actual_exit"
assert_contains "(a) --version prints version" "$VERSION_OUT" "codegen-call"
assert_contains "(a) --version contains 0.1.0" "$VERSION_OUT" "0.1.0"

# ─────────────────────────────────────────────────────────────────────────────
# Test (b): missing --harness exits 2 with usage on stderr
# ─────────────────────────────────────────────────────────────────────────────
CC_B="$(make_cc_root cc_b)"
actual_exit=0
STDERR_B="$("$CC_B/codegen-call" \
    --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" \
    "some prompt" 2>&1 || true)" || true
actual_exit=0
"$CC_B/codegen-call" \
    --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" \
    "some prompt" 2>/dev/null || actual_exit=$?
check "(b) missing --harness exits 2" "2" "$actual_exit"
assert_contains "(b) usage mentions harness" "$STDERR_B" "harness"

# ─────────────────────────────────────────────────────────────────────────────
# Test (c): missing required args each exit 2
# ─────────────────────────────────────────────────────────────────────────────
CC_C="$(make_cc_root cc_c)"
# Make a valid dispatch stub to ensure failures are from arg parsing, not dispatch
mkdir -p "$CC_C/harnesses/claude"
make_stub "$CC_C/harnesses/claude/call-dispatch.sh" 'printf '"'"'{"result":{"status":"success","value":"ok","reason":null,"retry_meta":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'"'"''

# missing --model
actual_exit=0
"$CC_C/codegen-call" --harness=claude_code --effort=low \
    --system-prompt "@$SP_FILE" "prompt" 2>/dev/null || actual_exit=$?
check "(c) missing --model exits 2" "2" "$actual_exit"

# missing --effort
actual_exit=0
"$CC_C/codegen-call" --harness=claude_code --model=haiku \
    --system-prompt "@$SP_FILE" "prompt" 2>/dev/null || actual_exit=$?
check "(c) missing --effort exits 2" "2" "$actual_exit"

# missing --system-prompt
actual_exit=0
"$CC_C/codegen-call" --harness=claude_code --model=haiku --effort=low \
    "prompt" 2>/dev/null || actual_exit=$?
check "(c) missing --system-prompt exits 2" "2" "$actual_exit"

# missing PROMPT
actual_exit=0
"$CC_C/codegen-call" --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" 2>/dev/null || actual_exit=$?
check "(c) missing PROMPT exits 2" "2" "$actual_exit"

# ─────────────────────────────────────────────────────────────────────────────
# Test (d): invalid --harness=foo exits 2
# ─────────────────────────────────────────────────────────────────────────────
CC_D="$(make_cc_root cc_d)"
actual_exit=0
"$CC_D/codegen-call" --harness=foo --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "prompt" 2>/dev/null || actual_exit=$?
check "(d) invalid --harness exits 2" "2" "$actual_exit"

# ─────────────────────────────────────────────────────────────────────────────
# Test (e): missing @<path> for --system-prompt exits 2
# ─────────────────────────────────────────────────────────────────────────────
CC_E="$(make_cc_root cc_e)"
actual_exit=0
"$CC_E/codegen-call" --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@/nonexistent/path/system_prompt.txt" "prompt" 2>/dev/null || actual_exit=$?
check "(e) missing @path for --system-prompt exits 2" "2" "$actual_exit"

# ─────────────────────────────────────────────────────────────────────────────
# Test (f): claude_code success fixture
# ─────────────────────────────────────────────────────────────────────────────
SUCCESS_ENVELOPE='{"result":{"status":"success","value":"Hello world","reason":null,"retry_meta":null},"usage":{"input_tokens":42,"output_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":500,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'

CC_F="$(make_cc_root cc_f)"
make_claude_dispatch_stub "$CC_F" "printf '%s\n' '${SUCCESS_ENVELOPE}'"

actual_exit=0
OUT_F="$("$CC_F/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "hello" 2>/dev/null)" || actual_exit=$?

check "(f) claude_code success exits 0" "0" "$actual_exit"
assert_jq "(f) result.status == success" "$OUT_F" ".result.status" "success"
assert_jq "(f) harness == claude_code" "$OUT_F" ".harness" "claude_code"
assert_jq_truthy "(f) usage.input_tokens > 0" "$OUT_F" ".usage.input_tokens > 0"

# ─────────────────────────────────────────────────────────────────────────────
# Test (g): claude_code schema_retry_exhausted fixture
# ─────────────────────────────────────────────────────────────────────────────
RETRY_ENVELOPE='{"result":{"status":"schema_retry_exhausted","value":null,"reason":"max retries exceeded","retry_meta":{"retries":3,"last_error":"malformed JSON"}},"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.002,"latency_ms":1200,"model":"haiku","num_turns":3},"error":null,"harness":"claude_code"}'

CC_G="$(make_cc_root cc_g)"
make_claude_dispatch_stub "$CC_G" "printf '%s\n' '${RETRY_ENVELOPE}'"

actual_exit=0
OUT_G="$("$CC_G/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "schema test" 2>/dev/null)" || actual_exit=$?

check "(g) schema_retry_exhausted exits 0" "0" "$actual_exit"
assert_jq "(g) result.status == schema_retry_exhausted" "$OUT_G" ".result.status" "schema_retry_exhausted"
assert_jq "(g) retry_meta.retries == 3" "$OUT_G" ".result.retry_meta.retries" "3"
assert_jq_truthy "(g) retry_meta.last_error non-null" "$OUT_G" '.result.retry_meta.last_error != null'

# ─────────────────────────────────────────────────────────────────────────────
# Test (h): claude_code with --json-schema returning structured JSON object
# ─────────────────────────────────────────────────────────────────────────────
SCHEMA_FILE="$BASE_TMP/schema.json"
printf '{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}' >"$SCHEMA_FILE"

STRUCT_ENVELOPE='{"result":{"status":"success","value":{"name":"Alice"},"reason":null,"retry_meta":null},"usage":{"input_tokens":55,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":600,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'

CC_H="$(make_cc_root cc_h)"
make_claude_dispatch_stub "$CC_H" "printf '%s\n' '${STRUCT_ENVELOPE}'"

actual_exit=0
OUT_H="$("$CC_H/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" \
    --json-schema "@$SCHEMA_FILE" \
    "structured test" 2>/dev/null)" || actual_exit=$?

check "(h) json-schema exits 0" "0" "$actual_exit"
assert_jq "(h) result.status == success" "$OUT_H" ".result.status" "success"
assert_jq_truthy "(h) result.value is object" "$OUT_H" '(.result.value | type) == "object"'

# ─────────────────────────────────────────────────────────────────────────────
# Test (i): pi success fixture (agent_end with assistant text)
# ─────────────────────────────────────────────────────────────────────────────
PI_SUCCESS_ENVELOPE='{"result":{"status":"success","value":"The answer is 42","reason":null,"retry_meta":null},"usage":{"input_tokens":30,"output_tokens":8,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":400,"model":"gpt-5","num_turns":1},"error":null,"harness":"pi"}'

CC_I="$(make_cc_root cc_i)"
make_pi_dispatch_stub "$CC_I" "printf '%s\n' '${PI_SUCCESS_ENVELOPE}'"

actual_exit=0
OUT_I="$("$CC_I/codegen-call" \
    --harness=pi --model=gpt-5 --effort=high \
    --system-prompt "@$SP_FILE" "pi test" 2>/dev/null)" || actual_exit=$?

check "(i) pi success exits 0" "0" "$actual_exit"
assert_jq "(i) result.status == success" "$OUT_I" ".result.status" "success"
assert_jq "(i) harness == pi" "$OUT_I" ".harness" "pi"

# ─────────────────────────────────────────────────────────────────────────────
# Test (j): pi empty reply → failed
# ─────────────────────────────────────────────────────────────────────────────
PI_EMPTY_ENVELOPE='{"result":{"status":"failed","value":null,"reason":"pi returned empty reply","retry_meta":null},"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":300,"model":"gpt-5","num_turns":1},"error":null,"harness":"pi"}'

CC_J="$(make_cc_root cc_j)"
make_pi_dispatch_stub "$CC_J" "printf '%s\n' '${PI_EMPTY_ENVELOPE}'"

actual_exit=0
OUT_J="$("$CC_J/codegen-call" \
    --harness=pi --model=gpt-5 --effort=high \
    --system-prompt "@$SP_FILE" "pi empty test" 2>/dev/null)" || actual_exit=$?

check "(j) pi empty reply exits 0" "0" "$actual_exit"
assert_jq "(j) result.status == failed" "$OUT_J" ".result.status" "failed"

# ─────────────────────────────────────────────────────────────────────────────
# Test (l): exit codes — success→0; harness exits non-zero→codegen-call exits 1
# ─────────────────────────────────────────────────────────────────────────────

# Success: dispatch exits 0
CC_L0="$(make_cc_root cc_l0)"
make_claude_dispatch_stub "$CC_L0" "printf '%s\n' '${SUCCESS_ENVELOPE}'; exit 0"
actual_exit=0
"$CC_L0/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "test" 2>/dev/null || actual_exit=$?
check "(l) dispatch exit 0 → codegen-call exits 0" "0" "$actual_exit"

# Failure: dispatch exits 1
ERROR_ENVELOPE='{"result":{"status":"failed","value":null,"reason":"infra error","retry_meta":null},"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"haiku","num_turns":0},"error":"claude exited 1","harness":"claude_code"}'
CC_L1="$(make_cc_root cc_l1)"
make_claude_dispatch_stub "$CC_L1" "printf '%s\n' '${ERROR_ENVELOPE}'; exit 1"
actual_exit=0
OUT_L1="$("$CC_L1/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "test" 2>/dev/null || true)"
"$CC_L1/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "test" 2>/dev/null || actual_exit=$?
check "(l) dispatch exit 1 → codegen-call exits 1" "1" "$actual_exit"
# Error envelope should still appear on stdout
assert_jq "(l) error envelope on stdout when exit 1" "$OUT_L1" ".result.status" "failed"

# ─────────────────────────────────────────────────────────────────────────────
# Test (m): envelope validates against contract (all required keys present)
# ─────────────────────────────────────────────────────────────────────────────
CC_M="$(make_cc_root cc_m)"
make_claude_dispatch_stub "$CC_M" "printf '%s\n' '${SUCCESS_ENVELOPE}'"

OUT_M="$("$CC_M/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "validate" 2>/dev/null)"

# Validate top-level keys
assert_jq_truthy "(m) .result exists" "$OUT_M" 'has("result")'
assert_jq_truthy "(m) .usage exists" "$OUT_M" 'has("usage")'
assert_jq_truthy "(m) .error key exists" "$OUT_M" 'has("error")'
assert_jq_truthy "(m) .harness exists" "$OUT_M" 'has("harness")'

# Validate result sub-keys
assert_jq_truthy "(m) .result.status exists" "$OUT_M" '.result | has("status")'
assert_jq_truthy "(m) .result.value key exists" "$OUT_M" '.result | has("value")'
assert_jq_truthy "(m) .result.reason key exists" "$OUT_M" '.result | has("reason")'
assert_jq_truthy "(m) .result has NO clarifying_question key" "$OUT_M" '.result | has("clarifying_question") | not'
assert_jq_truthy "(m) .result.retry_meta key exists" "$OUT_M" '.result | has("retry_meta")'

# Validate usage sub-keys
assert_jq_truthy "(m) .usage.input_tokens exists" "$OUT_M" '.usage | has("input_tokens")'
assert_jq_truthy "(m) .usage.output_tokens exists" "$OUT_M" '.usage | has("output_tokens")'
assert_jq_truthy "(m) .usage.cache_read_input_tokens exists" "$OUT_M" '.usage | has("cache_read_input_tokens")'
assert_jq_truthy "(m) .usage.cache_creation_input_tokens exists" "$OUT_M" '.usage | has("cache_creation_input_tokens")'
assert_jq_truthy "(m) .usage.cost_usd exists" "$OUT_M" '.usage | has("cost_usd")'
assert_jq_truthy "(m) .usage.latency_ms exists" "$OUT_M" '.usage | has("latency_ms")'
assert_jq_truthy "(m) .usage.model exists" "$OUT_M" '.usage | has("model")'
assert_jq_truthy "(m) .usage.num_turns exists" "$OUT_M" '.usage | has("num_turns")'

# Validate types
assert_jq_truthy "(m) .result.status is string" "$OUT_M" '(.result.status | type) == "string"'
assert_jq_truthy "(m) .usage.input_tokens is number" "$OUT_M" '(.usage.input_tokens | type) == "number"'
assert_jq_truthy "(m) .usage.output_tokens is number" "$OUT_M" '(.usage.output_tokens | type) == "number"'
assert_jq_truthy "(m) .usage.latency_ms is number" "$OUT_M" '(.usage.latency_ms | type) == "number"'
assert_jq_truthy "(m) .harness is string" "$OUT_M" '(.harness | type) == "string"'

# ─────────────────────────────────────────────────────────────────────────────
# Test (n): --role is unknown flag — passing --role=x exits 2
# ─────────────────────────────────────────────────────────────────────────────
CC_N="$(make_cc_root cc_n)"
actual_exit=0
"$CC_N/codegen-call" --harness=claude_code --role=x --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "prompt" 2>/dev/null || actual_exit=$?
check "(n) --role=x exits 2 as unknown flag" "2" "$actual_exit"

# Also verify usage text does not mention --role
USAGE_N="$("$CC_N/codegen-call" 2>&1 || true)"
ROLE_IN_USAGE=0
[[ "$USAGE_N" == *"--role"* ]] && ROLE_IN_USAGE=1
check "(n) usage does not mention --role" "0" "$ROLE_IN_USAGE"

# ─────────────────────────────────────────────────────────────────────────────
# Test (q): --resume <sid> round-trips into CODEGEN_CALL_RESUME
# ─────────────────────────────────────────────────────────────────────────────
CC_Q="$(make_cc_root cc_q)"
make_claude_dispatch_stub "$CC_Q" 'printf "%s" "$CODEGEN_CALL_RESUME" > "'"$BASE_TMP"'/resume_seen.txt"; printf '"'"'%s\n'"'"' '"'"'{"result":{"status":"success","value":"ok","reason":null,"retry_meta":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code","session_id":null}'"'"''

actual_exit=0
"$CC_Q/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --resume=warm-session-123 \
    "resume test" >/dev/null 2>/dev/null || actual_exit=$?
check "(q) --resume round-trip exits 0" "0" "$actual_exit"
RESUME_SEEN="$(cat "$BASE_TMP/resume_seen.txt" 2>/dev/null || true)"
check "(q) CODEGEN_CALL_RESUME carries the session id" "warm-session-123" "$RESUME_SEEN"

# ─────────────────────────────────────────────────────────────────────────────
# Test (q2): --session-id <sid> round-trips into CODEGEN_CALL_SESSION_ID and
# claude leg builds --session-id (not --resume) when only --session-id is set
# ─────────────────────────────────────────────────────────────────────────────
CC_Q2="$(make_cc_root cc_q2)"
make_claude_dispatch_stub "$CC_Q2" 'printf "%s" "$CODEGEN_CALL_SESSION_ID" > "'"$BASE_TMP"'/session_id_seen.txt"; printf '"'"'%s\n'"'"' '"'"'{"result":{"status":"success","value":"ok","reason":null,"retry_meta":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code","session_id":null}'"'"''

actual_exit=0
"$CC_Q2/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --session-id=cold-session-456 \
    "session-id test" >/dev/null 2>/dev/null || actual_exit=$?
check "(q2) --session-id round-trip exits 0" "0" "$actual_exit"
SESSION_ID_SEEN="$(cat "$BASE_TMP/session_id_seen.txt" 2>/dev/null || true)"
check "(q2) CODEGEN_CALL_SESSION_ID carries the minted id" "cold-session-456" "$SESSION_ID_SEEN"

# --print-argv proves claude leg builds --session-id (not --resume) when only
# --session-id is set — needs the REAL call-dispatch.sh (the fixture stub
# above has no --print-argv logic), mirrors test (t2)'s pattern.
CC_Q2_ARGV="$(make_cc_root cc_q2_argv)"
mkdir -p "$CC_Q2_ARGV/harnesses/claude"
cp "$REAL_CLAUDE_HARNESS/call-dispatch.sh" "$CC_Q2_ARGV/harnesses/claude/call-dispatch.sh"

ARGV_Q2="$("$CC_Q2_ARGV/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --session-id=cold-session-456 --print-argv \
    "session-id test" 2>/dev/null)" || true
Q2_HAS_SESSION_FLAG=0
[[ "$ARGV_Q2" == *"--session-id"*"cold-session-456"* ]] && Q2_HAS_SESSION_FLAG=1
check "(q2) --print-argv shows --session-id when only --session-id is set" "1" "$Q2_HAS_SESSION_FLAG"
Q2_HAS_RESUME_FLAG=0
[[ "$ARGV_Q2" == *"--resume"* ]] && Q2_HAS_RESUME_FLAG=1
check "(q2) --print-argv shows no --resume when only --session-id is set" "0" "$Q2_HAS_RESUME_FLAG"

# ─────────────────────────────────────────────────────────────────────────────
# Test (q3): --resume wins over --session-id when both are set (mutual exclusion)
# ─────────────────────────────────────────────────────────────────────────────
ARGV_Q3="$("$CC_Q2_ARGV/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --resume=warm-wins --session-id=cold-loses --print-argv \
    "both flags test" 2>/dev/null)" || true
Q3_HAS_RESUME=0
[[ "$ARGV_Q3" == *"--resume"*"warm-wins"* ]] && Q3_HAS_RESUME=1
check "(q3) --resume wins when both --resume and --session-id are set" "1" "$Q3_HAS_RESUME"
Q3_HAS_COLD_SESSION=0
[[ "$ARGV_Q3" == *"cold-loses"* ]] && Q3_HAS_COLD_SESSION=1
check "(q3) --session-id value is dropped when --resume also set" "0" "$Q3_HAS_COLD_SESSION"

# ─────────────────────────────────────────────────────────────────────────────
# Test (r): pi --agent=committer resolves agent definition and mints session_id
# ─────────────────────────────────────────────────────────────────────────────
CC_R="$(make_cc_root cc_r)"

mkdir -p "$CC_R/templates/generated/pi/agent"
printf -- '---\nname: committer\ndescription: d\nmodel: haiku\ntools: bash, edit, grep, read\n---\n# Committer\n\nYou are a committer specialist.' >"$CC_R/templates/generated/pi/agent/committer.md"

# Stub that echoes a minted session_id
make_pi_dispatch_stub "$CC_R" 'printf '"'"'{"result":{"status":"success","value":"committed","reason":null,"retry_meta":null},"usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":200,"model":"gpt-5","num_turns":1},"error":null,"harness":"pi","session_id":"r-minted-session"}'"'"''

actual_exit=0
OUT_R="$("$CC_R/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=committer "commit test" 2>/dev/null)" || actual_exit=$?

check "(r) pi --agent=committer exits 0" "0" "$actual_exit"
assert_jq "(r) result.status == success" "$OUT_R" ".result.status" "success"
assert_jq "(r) harness == pi" "$OUT_R" ".harness" "pi"
SESSION_ID_R="$(printf '%s' "$OUT_R" | jq -r '.session_id')"
check "(r) pi mints non-null session_id for agent call" "false" "$([[ "$SESSION_ID_R" == "null" ]] && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: real pi dispatch + a stubbed `pi` binary on PATH that captures argv
# and the --system-prompt value to files the test can grep. Used by (r2)-(r5)
# to exercise the ACTUAL frontmatter-strip + --tools emission logic in
# harnesses/pi/call-dispatch.sh (not a call-dispatch stub).
# ─────────────────────────────────────────────────────────────────────────────
make_pi_binary_stub() {
    local bindir="$1"
    local argv_file="$2"
    local sp_file="$3"
    mkdir -p "$bindir"
    cat >"$bindir/pi" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$argv_file"
prev=""
for a in "\$@"; do
    if [[ "\$prev" == "--system-prompt" ]]; then
        printf '%s' "\$a" > "$sp_file"
    fi
    prev="\$a"
done
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}'
STUB
    chmod +x "$bindir/pi"
}

setup_real_pi_dispatch() {
    local cc_root="$1"
    local role="$2"
    local agent_body="$3"
    mkdir -p "$cc_root/templates/generated/pi/agent"
    printf '%s' "$agent_body" >"$cc_root/templates/generated/pi/agent/$role.md"
    mkdir -p "$cc_root/harnesses/pi"
    cp "$REAL_PI_HARNESS/call-dispatch.sh" "$cc_root/harnesses/pi/call-dispatch.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test (r2): --system-prompt (real dispatch) contains only the body — no
# leading '---' and no 'tools:' line leaked from the frontmatter.
# ─────────────────────────────────────────────────────────────────────────────
CC_R2="$(make_cc_root cc_r2)"
setup_real_pi_dispatch "$CC_R2" "committer" '---
name: committer
description: d
model: haiku
tools: bash, edit, grep, read
---
# Committer

You are a committer specialist.'

R2_BIN="$BASE_TMP/cc_r2_bin"
R2_ARGV="$BASE_TMP/cc_r2_argv.txt"
R2_SP="$BASE_TMP/cc_r2_sp.txt"
make_pi_binary_stub "$R2_BIN" "$R2_ARGV" "$R2_SP"

# HOME override: _resolve_pi_agent checks $HOME/.pi/agent/agents/<role>.md
# FIRST — an installed agent on the operator's real machine would shadow the
# fixture. Point HOME at an empty dir so only the fixture resolves.
R2_HOME="$BASE_TMP/cc_r2_home"
mkdir -p "$R2_HOME"

actual_exit=0
HOME="$R2_HOME" PATH="$R2_BIN:$PATH" "$CC_R2/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=committer "commit test" >/dev/null 2>/dev/null || actual_exit=$?
check "(r2) real pi dispatch exits 0" "0" "$actual_exit"

SP_R2="$(cat "$R2_SP" 2>/dev/null || true)"
assert_contains "(r2) system-prompt contains body" "$SP_R2" "# Committer"
if [[ "$SP_R2" == *"tools:"* ]]; then
    printf 'FAIL: (r2) system-prompt leaks frontmatter tools: line\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "(r2) system-prompt has no tools: line"
    pass=$((pass + 1))
fi
if [[ "$SP_R2" == "---"* ]]; then
    printf 'FAIL: (r2) system-prompt leaks leading ---\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "(r2) system-prompt has no leading ---"
    pass=$((pass + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (r3): pi argv carries --tools with the frontmatter's tools: value.
# ─────────────────────────────────────────────────────────────────────────────
ARGV_R2="$(cat "$R2_ARGV" 2>/dev/null || true)"
assert_contains "(r3) pi argv carries --tools with frontmatter value" "$ARGV_R2" "--tools bash, edit, grep, read"

# ─────────────────────────────────────────────────────────────────────────────
# Test (r4): explicit --allowed-tools wins over agent frontmatter.
# ─────────────────────────────────────────────────────────────────────────────
CC_R4="$(make_cc_root cc_r4)"
setup_real_pi_dispatch "$CC_R4" "committer" '---
name: committer
description: d
model: haiku
tools: bash, edit, grep, read
---
# Committer

You are a committer specialist.'

R4_BIN="$BASE_TMP/cc_r4_bin"
R4_ARGV="$BASE_TMP/cc_r4_argv.txt"
R4_SP="$BASE_TMP/cc_r4_sp.txt"
make_pi_binary_stub "$R4_BIN" "$R4_ARGV" "$R4_SP"

R4_HOME="$BASE_TMP/cc_r4_home"
mkdir -p "$R4_HOME"

actual_exit=0
HOME="$R4_HOME" PATH="$R4_BIN:$PATH" "$CC_R4/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=committer --allowed-tools=read "commit test" >/dev/null 2>/dev/null || actual_exit=$?
check "(r4) explicit --allowed-tools + --agent exits 0" "0" "$actual_exit"
ARGV_R4="$(cat "$R4_ARGV" 2>/dev/null || true)"
assert_contains "(r4) explicit --allowed-tools wins over frontmatter" "$ARGV_R4" "--tools read"

# ─────────────────────────────────────────────────────────────────────────────
# Test (r5): frontmatter-less legacy agent file → body = whole file, no --tools.
# ─────────────────────────────────────────────────────────────────────────────
CC_R5="$(make_cc_root cc_r5)"
setup_real_pi_dispatch "$CC_R5" "committer" '# Committer

You are a committer specialist.'

R5_BIN="$BASE_TMP/cc_r5_bin"
R5_ARGV="$BASE_TMP/cc_r5_argv.txt"
R5_SP="$BASE_TMP/cc_r5_sp.txt"
make_pi_binary_stub "$R5_BIN" "$R5_ARGV" "$R5_SP"

R5_HOME="$BASE_TMP/cc_r5_home"
mkdir -p "$R5_HOME"

actual_exit=0
HOME="$R5_HOME" PATH="$R5_BIN:$PATH" "$CC_R5/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=committer "commit test" >/dev/null 2>/dev/null || actual_exit=$?
check "(r5) legacy frontmatter-less agent exits 0" "0" "$actual_exit"
SP_R5="$(cat "$R5_SP" 2>/dev/null || true)"
assert_contains "(r5) legacy agent body is whole file" "$SP_R5" "# Committer"
ARGV_R5="$(cat "$R5_ARGV" 2>/dev/null || true)"
if [[ "$ARGV_R5" == *"--tools"* ]]; then
    printf 'FAIL: (r5) legacy frontmatter-less agent must not emit --tools\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "(r5) legacy frontmatter-less agent emits no --tools"
    pass=$((pass + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (s): pi --agent=nonexistent_role exits 2 with error on stderr
# ─────────────────────────────────────────────────────────────────────────────
CC_S="$(make_cc_root cc_s)"
mkdir -p "$CC_S/templates/generated/pi/agent"

# Copy the REAL pi dispatch so agent resolution actually runs
mkdir -p "$CC_S/harnesses/pi"
cp "$REAL_PI_HARNESS/call-dispatch.sh" "$CC_S/harnesses/pi/call-dispatch.sh"

actual_exit=0
STDERR_S="$("$CC_S/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=nonexistent_role "test" 2>&1 >/dev/null || true)"

# Verify exit code is 2
"$CC_S/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=nonexistent_role "test" >/dev/null 2>/dev/null || actual_exit=$?
check "(s) pi --agent=nonexistent_role exits 2" "2" "$actual_exit"
assert_contains "(s) stderr mentions agent not found" "$STDERR_S" "agent definition not found"

# ─────────────────────────────────────────────────────────────────────────────
# Test (t): pi --agent with --resume round-trips session_id
# ─────────────────────────────────────────────────────────────────────────────
CC_T="$(make_cc_root cc_t)"

mkdir -p "$CC_T/templates/generated/pi/agent"
printf '# Developer\n\nYou are a developer.' >"$CC_T/templates/generated/pi/agent/developer.md"

# Stub that captures CODEGEN_CALL_RESUME and echoes it back in session_id
make_pi_dispatch_stub "$CC_T" 'RESUME_VAL="${CODEGEN_CALL_RESUME:-}"; printf '"'"'{"result":{"status":"success","value":"done","reason":null,"retry_meta":null},"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"gpt-5","num_turns":1},"error":null,"harness":"pi","session_id":"%s"}'"'"' "$RESUME_VAL"'

actual_exit=0
OUT_T="$("$CC_T/codegen-call" \
    --harness=pi --model=gpt-5 --effort=low \
    --agent=developer --resume=test-session-456 \
    "resume with agent test" 2>/dev/null)" || actual_exit=$?

check "(t) pi --agent with --resume exits 0" "0" "$actual_exit"
assert_jq "(t) session_id round-trips with --resume" "$OUT_T" ".session_id" "test-session-456"

# ─────────────────────────────────────────────────────────────────────────────
# Test (q): --agents value missing @ prefix exits 2
# ─────────────────────────────────────────────────────────────────────────────
CC_Q2="$(make_cc_root cc_q2)"
actual_exit=0
"$CC_Q2/codegen-call" --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --agents "not-an-at-path" "prompt" 2>/dev/null || actual_exit=$?
check "(q) --agents missing @ exits 2" "2" "$actual_exit"

# ─────────────────────────────────────────────────────────────────────────────
# Test (r): --agents @<nonexistent-path> exits 2
# ─────────────────────────────────────────────────────────────────────────────
CC_R2="$(make_cc_root cc_r2)"
actual_exit=0
"$CC_R2/codegen-call" --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --agents "@/nonexistent/agents.json" "prompt" 2>/dev/null || actual_exit=$?
check "(r) --agents @nonexistent-path exits 2" "2" "$actual_exit"

# ─────────────────────────────────────────────────────────────────────────────
# Test (s2): --agents @<path> passed through to claude dispatch verbatim
# ─────────────────────────────────────────────────────────────────────────────
CC_S2="$(make_cc_root cc_s2)"
cp "$REAL_CLAUDE_HARNESS/call-dispatch.sh" "$(mkdir -p "$CC_S2/harnesses/claude" && echo "$CC_S2/harnesses/claude")/call-dispatch.sh"
AGENTS_FILE_S2="$BASE_TMP/agents_s2.json"
printf '{"probe-agent":{"description":"probe","prompt":"probe","tools":[]}}' >"$AGENTS_FILE_S2"

ARGV_LOG_S2="$BASE_TMP/argv_s2.log"
: >"$ARGV_LOG_S2"
STUB_BIN_S2="$BASE_TMP/stub_bin_s2"
mkdir -p "$STUB_BIN_S2"
cat >"$STUB_BIN_S2/claude" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a" >>"$ARGV_LOG_S2"; done
printf '{"type":"result","subtype":"success","result":"ok","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0,"duration_ms":10,"num_turns":1}\n'
STUBEOF
chmod +x "$STUB_BIN_S2/claude"

actual_exit=0
PATH="$STUB_BIN_S2:$PATH" "$CC_S2/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --agent=probe-agent --agents "@$AGENTS_FILE_S2" \
    "prompt" >/dev/null 2>/dev/null || actual_exit=$?
check "(s2) --agents passthrough call exits 0" "0" "$actual_exit"
assert_contains "(s2) claude argv carries --agents" "$(cat "$ARGV_LOG_S2")" "--agents"
assert_contains "(s2) claude argv carries agents JSON content" "$(cat "$ARGV_LOG_S2")" "probe-agent"

# ─────────────────────────────────────────────────────────────────────────────
# Test (t2): --print-argv dry-run on claude leg prints argv, exits 0, never execs claude
# ─────────────────────────────────────────────────────────────────────────────
CC_T2="$(make_cc_root cc_t2)"
mkdir -p "$CC_T2/harnesses/claude"
cp "$REAL_CLAUDE_HARNESS/call-dispatch.sh" "$CC_T2/harnesses/claude/call-dispatch.sh"

NEVER_CALLED_MARKER="$BASE_TMP/never_called_t2"
rm -f "$NEVER_CALLED_MARKER"
STUB_BIN_T2="$BASE_TMP/stub_bin_t2"
mkdir -p "$STUB_BIN_T2"
cat >"$STUB_BIN_T2/claude" <<STUBEOF
#!/usr/bin/env bash
touch "$NEVER_CALLED_MARKER"
printf '{"type":"result","subtype":"success","result":"ok","usage":{},"total_cost_usd":0,"duration_ms":1,"num_turns":1}\n'
STUBEOF
chmod +x "$STUB_BIN_T2/claude"

actual_exit=0
OUT_T2="$(PATH="$STUB_BIN_T2:$PATH" "$CC_T2/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" --print-argv \
    "dry run prompt" 2>/dev/null)" || actual_exit=$?

check "(t2) --print-argv exits 0" "0" "$actual_exit"
assert_contains "(t2) --print-argv output mentions model" "$OUT_T2" "haiku"
if [[ -f "$NEVER_CALLED_MARKER" ]]; then
    printf 'FAIL: (t2) --print-argv must never exec claude\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (u): usage<->parse parity — every parsed --flag appears in usage string,
# and every usage-mentioned --flag is parsed in the case block
# ─────────────────────────────────────────────────────────────────────────────
USAGE_LINE="$(grep -m1 '^Usage: codegen-call' <(sed -n '/^usage() {/,/^}/p' "$CODEGEN_CALL") || true)"
if [[ -z "$USAGE_LINE" ]]; then
    USAGE_LINE="$(grep -m1 'printf .Usage: codegen-call' "$CODEGEN_CALL" || true)"
fi

# --version is a standalone short-circuit flag documented in the header
# Flags list but intentionally omitted from the usage() synopsis line
# (it takes no other required args); exempt it from parity.
PARSED_FLAGS="$(sed -n '/^while \[\[ \$# -gt 0 \]\]; do/,/^done/p' "$CODEGEN_CALL" | grep -oE -- '--[a-zA-Z-]+' | grep -vxF -- '--version' | sort -u)"

MISSING_FROM_USAGE=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$USAGE_LINE" != *"$flag"* ]]; then
        printf 'FAIL: (u) flag %s parsed but missing from usage string\n' "$flag"
        MISSING_FROM_USAGE=$((MISSING_FROM_USAGE + 1))
    fi
done <<<"$PARSED_FLAGS"
check "(u) every parsed flag appears in usage string" "0" "$MISSING_FROM_USAGE"

USAGE_FLAGS="$(printf '%s' "$USAGE_LINE" | grep -oE -- '--[a-zA-Z-]+' | sort -u)"
MISSING_FROM_PARSE=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$PARSED_FLAGS" != *"$flag"* ]]; then
        printf 'FAIL: (u) flag %s in usage string but not parsed\n' "$flag"
        MISSING_FROM_PARSE=$((MISSING_FROM_PARSE + 1))
    fi
done <<<"$USAGE_FLAGS"
check "(u) every usage-mentioned flag is parsed" "0" "$MISSING_FROM_PARSE"

# ─────────────────────────────────────────────────────────────────────────────
# Test (snap): public flag surface snapshot — codegen-call's parsed flags
# must equal the committed fixture, in both directions. Parity (above) checks
# internal consistency; this checks stability — a flag deleted from both the
# parser and the usage string keeps parity green but must flip this snapshot RED.
# ─────────────────────────────────────────────────────────────────────────────
CC_FIXTURE="$HOOKS_DIR/fixtures/codegen-call-flags.txt"
CC_FIXTURE_FLAGS="$(grep -v '^#' "$CC_FIXTURE" | grep -v '^[[:space:]]*$' | sort -u)"

CC_SNAP_ADDED=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$CC_FIXTURE_FLAGS" != *"$flag"* ]]; then
        printf 'FAIL: (snap) flag %s parsed but NOT in committed fixture (surface grew — update the fixture deliberately)\n' "$flag"
        CC_SNAP_ADDED=$((CC_SNAP_ADDED + 1))
    fi
done <<<"$PARSED_FLAGS"
check "(snap) no parsed flag missing from fixture" "0" "$CC_SNAP_ADDED"

CC_SNAP_REMOVED=0
while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    if [[ "$PARSED_FLAGS" != *"$flag"* ]]; then
        printf 'FAIL: (snap) flag %s in committed fixture but NOT parsed (surface shrank — a flag was deleted!)\n' "$flag"
        CC_SNAP_REMOVED=$((CC_SNAP_REMOVED + 1))
    fi
done <<<"$CC_FIXTURE_FLAGS"
check "(snap) no fixture flag missing from parser" "0" "$CC_SNAP_REMOVED"

# ─────────────────────────────────────────────────────────────────────────────
# Test (o): codegen-call source contains zero role-name tokens
# ─────────────────────────────────────────────────────────────────────────────
ROLE_TOKEN_COUNT="$(grep -cE 'planner|developer|committer|reviewer|curator' "$CODEGEN_CALL" || true)"
ROLE_TOKEN_COUNT="${ROLE_TOKEN_COUNT:-0}"
check "(o) codegen-call has zero role-name tokens" "0" "$ROLE_TOKEN_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# Test (p): codegen-call source contains zero --append-system-prompt tokens
# ─────────────────────────────────────────────────────────────────────────────
APPEND_FLAG_COUNT="$(grep -cF -- '--append-system-prompt' "$CODEGEN_CALL" || true)"
APPEND_FLAG_COUNT="${APPEND_FLAG_COUNT:-0}"
check "(p) codegen-call has zero --append-system-prompt tokens" "0" "$APPEND_FLAG_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# Test (extdir): --extension accepts a package DIRECTORY, not just a file.
#
# pi resolves a package dir's entry itself (package.json main/pi.extensions),
# and the enforcement extension ships ONLY as a package dir — so the previous
# `-f`-only check rejected every pi loop role at 0 tokens with
# "--extension file not found". Uses --print-argv: pure argv assembly, no
# model call, no token spend.
# ─────────────────────────────────────────────────────────────────────────────
EXT_DIR="$(mktemp -d)"
mkdir -p "$EXT_DIR/dist"
printf '{"name":"probe-ext","main":"dist/index.js"}' >"$EXT_DIR/package.json"
printf 'export default {};' >"$EXT_DIR/dist/index.js"
SP_FIXTURE="$EXT_DIR/system-prompt.txt"
printf 'You are a probe.' >"$SP_FIXTURE"

EXT_DIR_RC=0
CODEGEN_DIR="$CODEGEN_ROOT" "$CODEGEN_CALL" \
    --harness=pi \
    --model=openai-codex/gpt-5.6-terra \
    --effort=low \
    --system-prompt="@$SP_FIXTURE" \
    --extension="@$EXT_DIR" \
    --print-argv \
    "PING" >/dev/null 2>&1 || EXT_DIR_RC=$?
check "(extdir) --extension accepts a package directory" "0" "$EXT_DIR_RC"

EXT_MISSING_RC=0
CODEGEN_DIR="$CODEGEN_ROOT" "$CODEGEN_CALL" \
    --harness=pi \
    --model=openai-codex/gpt-5.6-terra \
    --effort=low \
    --system-prompt="@$SP_FIXTURE" \
    --extension="@$EXT_DIR/nope" \
    --print-argv \
    "PING" >/dev/null 2>&1 || EXT_MISSING_RC=$?
check "(extdir2) --extension still rejects a nonexistent path" "2" "$EXT_MISSING_RC"

rm -rf "$EXT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
