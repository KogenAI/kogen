#!/usr/bin/env bash
# harnesses/claude/call-dispatch.sh — one-shot claude LLM call dispatch for codegen-call.
#
# Called by codegen-call via exec after env vars are set.
# Captures claude stream-json output, parses it into a normalized JSON envelope,
# emits the envelope on stdout.
# STDOUT: one JSON envelope object. STDERR: diagnostics only.

set -euo pipefail

# ── Millisecond timestamp helper ──────────────────────────────────────────────
# date +%s%N works on Linux and on macOS with coreutils. Fall back to perl.
_ts_ms() {
    local ns
    if ns=$(date +%s%N 2>/dev/null) && [[ "$ns" =~ ^[0-9]{13,}$ ]]; then
        printf '%d' "$((ns / 1000000))"
    else
        perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
    fi
}

# ── Read CODEGEN_CALL_* env vars ──────────────────────────────────────────────
SYSTEM_PROMPT="${CODEGEN_CALL_SYSTEM_PROMPT:?CODEGEN_CALL_SYSTEM_PROMPT not set}"
MODEL="${CODEGEN_CALL_MODEL:?CODEGEN_CALL_MODEL not set}"
EFFORT="${CODEGEN_CALL_EFFORT:?CODEGEN_CALL_EFFORT not set}"
PROMPT="${CODEGEN_CALL_PROMPT:?CODEGEN_CALL_PROMPT not set}"
JSON_SCHEMA_PATH="${CODEGEN_CALL_JSON_SCHEMA_PATH:-}"
JSON_SCHEMA_CONTENT="${CODEGEN_CALL_JSON_SCHEMA:-}"
ALLOWED_TOOLS="${CODEGEN_CALL_ALLOWED_TOOLS:-}"
ALLOWED_TOOLS_SET="${CODEGEN_CALL_ALLOWED_TOOLS_SET:-}"
SETTINGS_PATH="${CODEGEN_CALL_SETTINGS_PATH:-}"

# ── Build claude argv ─────────────────────────────────────────────────────────
COMMON_FLAGS=(
    --dangerously-skip-permissions
    --print
    --output-format stream-json
    --verbose
    --setting-sources project
    --strict-mcp-config
    --no-session-persistence
    --disable-slash-commands
    --system-prompt "$SYSTEM_PROMPT"
    --model "$MODEL"
    --effort "$EFFORT"
    --max-turns 1
)

# --tools: pass if explicitly set (including empty string = no tools)
if [[ -n "$ALLOWED_TOOLS_SET" ]]; then
    COMMON_FLAGS+=(--tools "$ALLOWED_TOOLS")
else
    COMMON_FLAGS+=(--tools "")
fi

# --json-schema: claude CLI accepts inline JSON string
if [[ -n "$JSON_SCHEMA_CONTENT" ]]; then
    COMMON_FLAGS+=(--json-schema "$JSON_SCHEMA_CONTENT")
fi

# --settings: path to settings JSON file
if [[ -n "$SETTINGS_PATH" ]]; then
    COMMON_FLAGS+=(--settings "$SETTINGS_PATH")
fi

# ── Capture claude output ─────────────────────────────────────────────────────
TMP_OUT="$(mktemp -t codegen-call-claude.XXXXXX.jsonl)"
trap 'rm -f "$TMP_OUT"' EXIT

START_TS_MS="$(_ts_ms)"

set +e
env \
    -u CLAUDECODE \
    -u CLAUDE_CODE_SSE_PORT \
    -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_EXECPATH \
    -u AI_AGENT \
    -u SECRET_KEY_BASE \
    ENABLE_PROMPT_CACHING_1H=1 \
    MAX_THINKING_TOKENS=0 \
    MCP_CONNECTION_NONBLOCKING=true \
    claude "${COMMON_FLAGS[@]}" -- "$PROMPT" >"$TMP_OUT" 2>&1
EXIT_CODE=$?
set -e

END_TS_MS="$(_ts_ms)"
LATENCY_MS=$((END_TS_MS - START_TS_MS))

# ── Parse stream-json into envelope ──────────────────────────────────────────
# Extract the last result event from stream-json
RESULT_EVENT="$(jq -c 'select(.type == "result")' "$TMP_OUT" 2>/dev/null | tail -1 || true)"

if [[ $EXIT_CODE -ne 0 ]] && [[ -z "$RESULT_EVENT" ]]; then
    # Claude binary failed with no parseable output
    TAIL_OUT="$(tail -c 500 "$TMP_OUT" 2>/dev/null || true)"
    jq -n \
        --arg error "claude exited ${EXIT_CODE}: ${TAIL_OUT}" \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: ("claude exited " + ($error | split(": ")[0] | ltrimstr("claude exited "))),
                clarifying_question: null,
                retry_meta: null
            },
            usage: {
                input_tokens: 0,
                output_tokens: 0,
                cache_read_input_tokens: 0,
                cache_creation_input_tokens: 0,
                cost_usd: 0,
                latency_ms: $latency_ms,
                model: $model,
                num_turns: 0
            },
            error: $error,
            harness: "claude_code"
        }'
    exit 1
fi

if [[ -z "$RESULT_EVENT" ]]; then
    # No result event found but exit code was 0 — malformed output
    TAIL_OUT="$(tail -c 500 "$TMP_OUT" 2>/dev/null || true)"
    jq -n \
        --arg tail_out "$TAIL_OUT" \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "no result event found in stream-json",
                clarifying_question: null,
                retry_meta: null
            },
            usage: {
                input_tokens: 0,
                output_tokens: 0,
                cache_read_input_tokens: 0,
                cache_creation_input_tokens: 0,
                cost_usd: 0,
                latency_ms: $latency_ms,
                model: $model,
                num_turns: 0
            },
            error: ("no result event; tail: " + $tail_out),
            harness: "claude_code"
        }'
    exit 0
fi

# Extract fields from result event
SUBTYPE="$(printf '%s' "$RESULT_EVENT" | jq -r '.subtype // "unknown"')"
IS_ERROR="$(printf '%s' "$RESULT_EVENT" | jq -r '.is_error // false')"
RESULT_TEXT="$(printf '%s' "$RESULT_EVENT" | jq -r '.result // ""')"
NUM_TURNS="$(printf '%s' "$RESULT_EVENT" | jq -r '.num_turns // 1')"
TOTAL_COST="$(printf '%s' "$RESULT_EVENT" | jq -r '.total_cost_usd // 0')"

# Extract usage tokens from result event
INPUT_TOKENS="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.input_tokens // 0')"
OUTPUT_TOKENS="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.output_tokens // 0')"
CACHE_READ="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.cache_read_input_tokens // 0')"
CACHE_CREATION="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.cache_creation_input_tokens // 0')"

# Determine status
STATUS=""
REASON=""
CLARIFYING_QUESTION=""
RETRY_META="null"

if [[ "$SUBTYPE" == "error_max_structured_output_retries" ]]; then
    STATUS="schema_retry_exhausted"
    REASON="$(printf '%s' "$RESULT_EVENT" | jq -r '.message // "max structured output retries exceeded"')"
    # Build retry_meta from result event
    RETRY_META="$(printf '%s' "$RESULT_EVENT" | jq -c '{retries: (.num_retries // 3), last_error: (.message // "max retries exceeded")}')"
elif [[ "$IS_ERROR" == "true" ]]; then
    STATUS="failed"
    REASON="$(printf '%s' "$RESULT_EVENT" | jq -r '.message // .result // "error"')"
elif [[ "$SUBTYPE" == "success" ]]; then
    # Clarifying question heuristic: text ends with "?" and no json-schema was passed
    if [[ -z "$JSON_SCHEMA_CONTENT" ]] && [[ "$RESULT_TEXT" =~ \?[[:space:]]*$ ]]; then
        STATUS="clarifying_question"
        CLARIFYING_QUESTION="$RESULT_TEXT"
    else
        STATUS="success"
    fi
else
    STATUS="failed"
    REASON="unexpected result subtype: $SUBTYPE"
fi

# Extract structured value
# If json-schema was requested, try to find JSON in the assistant message
VALUE_JSON="null"
if [[ -n "$JSON_SCHEMA_CONTENT" ]] && [[ "$STATUS" == "success" || "$STATUS" == "schema_retry_exhausted" ]]; then
    # Search for last assistant message with parseable JSON content
    LAST_ASSISTANT_JSON="$(
        jq -r '
            select(.type == "assistant") |
            .message.content[]? |
            select(.type == "text") |
            .text
        ' "$TMP_OUT" 2>/dev/null | tail -1 || true
    )"
    if [[ -n "$LAST_ASSISTANT_JSON" ]]; then
        # Try to extract JSON from the text (may be embedded)
        PARSED="$(printf '%s' "$LAST_ASSISTANT_JSON" | jq -c '.' 2>/dev/null || true)"
        if [[ -n "$PARSED" ]]; then
            VALUE_JSON="$PARSED"
        fi
    fi
    # Fall back to result text if no JSON found in assistant messages
    if [[ "$VALUE_JSON" == "null" ]] && [[ -n "$RESULT_TEXT" ]]; then
        PARSED="$(printf '%s' "$RESULT_TEXT" | jq -c '.' 2>/dev/null || true)"
        if [[ -n "$PARSED" ]]; then
            VALUE_JSON="$PARSED"
        fi
    fi
elif [[ "$STATUS" == "success" || "$STATUS" == "clarifying_question" ]]; then
    VALUE_JSON="$(printf '%s' "$RESULT_TEXT" | jq -Rs '.')"
elif [[ -n "$RESULT_TEXT" ]]; then
    VALUE_JSON="$(printf '%s' "$RESULT_TEXT" | jq -Rs '.')"
fi

# Build envelope
jq -n \
    --arg status "$STATUS" \
    --argjson value "$VALUE_JSON" \
    --arg reason "$REASON" \
    --arg cq "$CLARIFYING_QUESTION" \
    --argjson retry_meta "$RETRY_META" \
    --argjson input_tokens "$INPUT_TOKENS" \
    --argjson output_tokens "$OUTPUT_TOKENS" \
    --argjson cache_read "$CACHE_READ" \
    --argjson cache_creation "$CACHE_CREATION" \
    --argjson cost_usd "$TOTAL_COST" \
    --argjson latency_ms "$LATENCY_MS" \
    --arg model "$MODEL" \
    --argjson num_turns "$NUM_TURNS" \
    '{
        result: {
            status: $status,
            value: $value,
            reason: (if $reason == "" then null else $reason end),
            clarifying_question: (if $cq == "" then null else $cq end),
            retry_meta: $retry_meta
        },
        usage: {
            input_tokens: $input_tokens,
            output_tokens: $output_tokens,
            cache_read_input_tokens: $cache_read,
            cache_creation_input_tokens: $cache_creation,
            cost_usd: $cost_usd,
            latency_ms: $latency_ms,
            model: $model,
            num_turns: $num_turns
        },
        error: null,
        harness: "claude_code"
    }'
exit 0
