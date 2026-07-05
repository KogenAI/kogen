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
# (k) clarifying-question heuristic: text ending "?" without --json-schema → clarifying_question
# (l) exit codes: success→0; harness exits non-zero→codegen-call exits 1, error-envelope on stdout
# (m) envelope JSON validates against contract (all required keys present, types correct)
# (o) codegen-call source contains zero role-name tokens (planner/developer/committer/reviewer/curator)
# (p) codegen-call source contains zero --append-system-prompt tokens (REPLACE-only identity)

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
make_stub "$CC_C/harnesses/claude/call-dispatch.sh" 'printf '"'"'{"result":{"status":"success","value":"ok","reason":null,"clarifying_question":null,"retry_meta":null},"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'"'"''

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
SUCCESS_ENVELOPE='{"result":{"status":"success","value":"Hello world","reason":null,"clarifying_question":null,"retry_meta":null},"usage":{"input_tokens":42,"output_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":500,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'

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
RETRY_ENVELOPE='{"result":{"status":"schema_retry_exhausted","value":null,"reason":"max retries exceeded","clarifying_question":null,"retry_meta":{"retries":3,"last_error":"malformed JSON"}},"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.002,"latency_ms":1200,"model":"haiku","num_turns":3},"error":null,"harness":"claude_code"}'

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

STRUCT_ENVELOPE='{"result":{"status":"success","value":{"name":"Alice"},"reason":null,"clarifying_question":null,"retry_meta":null},"usage":{"input_tokens":55,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":600,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'

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
PI_SUCCESS_ENVELOPE='{"result":{"status":"success","value":"The answer is 42","reason":null,"clarifying_question":null,"retry_meta":null},"usage":{"input_tokens":30,"output_tokens":8,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0.001,"latency_ms":400,"model":"gpt-5","num_turns":1},"error":null,"harness":"pi"}'

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
PI_EMPTY_ENVELOPE='{"result":{"status":"failed","value":null,"reason":"pi returned empty reply","clarifying_question":null,"retry_meta":null},"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":300,"model":"gpt-5","num_turns":1},"error":null,"harness":"pi"}'

CC_J="$(make_cc_root cc_j)"
make_pi_dispatch_stub "$CC_J" "printf '%s\n' '${PI_EMPTY_ENVELOPE}'"

actual_exit=0
OUT_J="$("$CC_J/codegen-call" \
    --harness=pi --model=gpt-5 --effort=high \
    --system-prompt "@$SP_FILE" "pi empty test" 2>/dev/null)" || actual_exit=$?

check "(j) pi empty reply exits 0" "0" "$actual_exit"
assert_jq "(j) result.status == failed" "$OUT_J" ".result.status" "failed"

# ─────────────────────────────────────────────────────────────────────────────
# Test (k): clarifying-question heuristic
# ─────────────────────────────────────────────────────────────────────────────
CQ_ENVELOPE='{"result":{"status":"clarifying_question","value":"What is your preferred language?","reason":null,"clarifying_question":"What is your preferred language?","retry_meta":null},"usage":{"input_tokens":20,"output_tokens":6,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":200,"model":"haiku","num_turns":1},"error":null,"harness":"claude_code"}'

CC_K="$(make_cc_root cc_k)"
make_claude_dispatch_stub "$CC_K" "printf '%s\n' '${CQ_ENVELOPE}'"

actual_exit=0
OUT_K="$("$CC_K/codegen-call" \
    --harness=claude_code --model=haiku --effort=low \
    --system-prompt "@$SP_FILE" "ambiguous prompt" 2>/dev/null)" || actual_exit=$?

check "(k) clarifying_question exits 0" "0" "$actual_exit"
assert_jq "(k) result.status == clarifying_question" "$OUT_K" ".result.status" "clarifying_question"
assert_jq_truthy "(k) clarifying_question field non-null" "$OUT_K" '.result.clarifying_question != null'

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
ERROR_ENVELOPE='{"result":{"status":"failed","value":null,"reason":"infra error","clarifying_question":null,"retry_meta":null},"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cost_usd":0,"latency_ms":100,"model":"haiku","num_turns":0},"error":"claude exited 1","harness":"claude_code"}'
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
assert_jq_truthy "(m) .result.clarifying_question key exists" "$OUT_M" '.result | has("clarifying_question")'
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
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
