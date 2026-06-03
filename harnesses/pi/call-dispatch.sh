#!/usr/bin/env bash
# harnesses/pi/call-dispatch.sh — one-shot pi LLM call dispatch for codegen-call.
#
# Called by codegen-call via exec after env vars are set.
# Captures pi JSONL output, parses agent_end events into a normalized JSON envelope,
# emits the envelope on stdout.
# STDOUT: one JSON envelope object. STDERR: diagnostics only.

set -euo pipefail

if ! command -v pi >/dev/null 2>&1; then
    printf 'codegen-call (pi): pi binary not found in PATH\n' >&2
    printf 'Install: npm install -g @earendil-works/pi-coding-agent\n' >&2
    exit 127
fi

# ── Millisecond timestamp helper ──────────────────────────────────────────────
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
JSON_SCHEMA_CONTENT="${CODEGEN_CALL_JSON_SCHEMA:-}"
EXTENSION_PATH="${CODEGEN_CALL_EXTENSION_PATH:-}"

# ── Build prompt (embed JSON schema as instruction if provided) ───────────────
EFFECTIVE_PROMPT="$PROMPT"
if [[ -n "$JSON_SCHEMA_CONTENT" ]]; then
    EFFECTIVE_PROMPT="${PROMPT}

Respond with valid JSON matching this schema:
${JSON_SCHEMA_CONTENT}"
fi

# ── Build pi argv ─────────────────────────────────────────────────────────────
ARGS=(
    -p
    --mode json
    --no-session
    --no-context-files
    --system-prompt "$SYSTEM_PROMPT"
    --provider openai-codex
    --model "$MODEL"
    --thinking "$EFFORT"
)

if [[ -n "$EXTENSION_PATH" ]]; then
    ARGS+=(--extension "$EXTENSION_PATH")
fi

ARGS+=("$EFFECTIVE_PROMPT")

# ── Capture pi output ─────────────────────────────────────────────────────────
TMP_OUT="$(mktemp -t codegen-call-pi.XXXXXX.jsonl)"
trap 'rm -f "$TMP_OUT"' EXIT

START_TS_MS="$(_ts_ms)"

set +e
env \
    -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY \
    -u CURSOR_API_KEY \
    pi "${ARGS[@]}" </dev/null >"$TMP_OUT" 2>&1
EXIT_CODE=$?
set -e

END_TS_MS="$(_ts_ms)"
LATENCY_MS=$((END_TS_MS - START_TS_MS))

# ── Parse JSONL into envelope ─────────────────────────────────────────────────
# Find last agent_end event
AGENT_END_EVENT="$(jq -c 'select(.type == "agent_end")' "$TMP_OUT" 2>/dev/null | tail -1 || true)"

if [[ $EXIT_CODE -ne 0 ]] && [[ -z "$AGENT_END_EVENT" ]]; then
    TAIL_OUT="$(tail -c 500 "$TMP_OUT" 2>/dev/null || true)"
    jq -n \
        --arg error "pi exited ${EXIT_CODE}: ${TAIL_OUT}" \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "pi exited non-zero",
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
                num_turns: 1
            },
            error: $error,
            harness: "pi"
        }'
    exit 1
fi

if [[ -z "$AGENT_END_EVENT" ]]; then
    TAIL_OUT="$(tail -c 500 "$TMP_OUT" 2>/dev/null || true)"
    jq -n \
        --arg tail_out "$TAIL_OUT" \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "no agent_end event found in pi JSONL",
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
                num_turns: 1
            },
            error: ("no agent_end event; tail: " + $tail_out),
            harness: "pi"
        }'
    exit 0
fi

# Extract assistant text from messages array in agent_end event
# Messages may be an array of {role, content} objects
ASSISTANT_TEXT="$(
    printf '%s' "$AGENT_END_EVENT" | jq -r '
        .messages // [] |
        reverse |
        .[] |
        select(.role == "assistant") |
        (
            if (.content | type) == "array" then
                .content[] | select(.type == "text") | .text
            elif (.content | type) == "string" then
                .content
            else
                ""
            end
        )
    ' 2>/dev/null | head -1 || true
)"

# Extract usage from agent_end or from dedicated usage events in JSONL
INPUT_TOKENS="$(printf '%s' "$AGENT_END_EVENT" | jq -r '.usage.input_tokens // 0' 2>/dev/null || printf '0')"
OUTPUT_TOKENS="$(printf '%s' "$AGENT_END_EVENT" | jq -r '.usage.output_tokens // 0' 2>/dev/null || printf '0')"
CACHE_READ="$(printf '%s' "$AGENT_END_EVENT" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || printf '0')"
CACHE_CREATION="$(printf '%s' "$AGENT_END_EVENT" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || printf '0')"
COST_USD="$(printf '%s' "$AGENT_END_EVENT" | jq -r '.usage.cost_usd // 0' 2>/dev/null || printf '0')"
NUM_TURNS="$(printf '%s' "$AGENT_END_EVENT" | jq -r '.num_turns // 1' 2>/dev/null || printf '1')"

# Fall back to scanning JSONL for usage events if agent_end had no usage
if [[ "$INPUT_TOKENS" == "0" ]]; then
    USAGE_EVENT="$(jq -c 'select(.type == "usage")' "$TMP_OUT" 2>/dev/null | tail -1 || true)"
    if [[ -n "$USAGE_EVENT" ]]; then
        INPUT_TOKENS="$(printf '%s' "$USAGE_EVENT" | jq -r '.input_tokens // 0')"
        OUTPUT_TOKENS="$(printf '%s' "$USAGE_EVENT" | jq -r '.output_tokens // 0')"
        CACHE_READ="$(printf '%s' "$USAGE_EVENT" | jq -r '.cache_read_input_tokens // 0')"
        CACHE_CREATION="$(printf '%s' "$USAGE_EVENT" | jq -r '.cache_creation_input_tokens // 0')"
        COST_USD="$(printf '%s' "$USAGE_EVENT" | jq -r '.cost_usd // 0')"
    fi
fi

# Determine status
STATUS=""
REASON=""
CLARIFYING_QUESTION=""
VALUE_JSON="null"

if [[ -z "$ASSISTANT_TEXT" ]]; then
    STATUS="failed"
    REASON="pi returned empty reply"
elif [[ -n "$JSON_SCHEMA_CONTENT" ]]; then
    # JSON schema was requested: try to parse assistant text as JSON
    PARSED="$(printf '%s' "$ASSISTANT_TEXT" | jq -c '.' 2>/dev/null || true)"
    if [[ -n "$PARSED" ]]; then
        STATUS="success"
        VALUE_JSON="$PARSED"
    else
        STATUS="failed"
        REASON="pi returned non-JSON reply when JSON schema was expected"
        VALUE_JSON="$(printf '%s' "$ASSISTANT_TEXT" | jq -Rs '.')"
    fi
elif [[ -z "$JSON_SCHEMA_CONTENT" ]] && [[ "$ASSISTANT_TEXT" =~ \?[[:space:]]*$ ]]; then
    # Clarifying question heuristic (only when no JSON schema was requested)
    STATUS="clarifying_question"
    CLARIFYING_QUESTION="$ASSISTANT_TEXT"
    VALUE_JSON="$(printf '%s' "$ASSISTANT_TEXT" | jq -Rs '.')"
else
    STATUS="success"
    VALUE_JSON="$(printf '%s' "$ASSISTANT_TEXT" | jq -Rs '.')"
fi

# ── Schema validation (only when a schema was requested and call succeeded) ──
if [[ -n "$JSON_SCHEMA_CONTENT" ]] && [[ "$STATUS" == "success" ]] && [[ "$VALUE_JSON" != "null" ]]; then
    SCHEMA_TMP="$(mktemp -t codegen-call-schema.XXXXXX.json)"
    VALUE_TMP="$(mktemp -t codegen-call-value.XXXXXX.json)"
    printf '%s' "$JSON_SCHEMA_CONTENT" >"$SCHEMA_TMP"
    printf '%s' "$VALUE_JSON" >"$VALUE_TMP"
    VALIDATE_ERR=""
    VALIDATE_CODE=0
    VALIDATE_ERR="$(node "$(dirname "${BASH_SOURCE[0]}")/../claude/hooks/lib/schema-validate.js" "$SCHEMA_TMP" "$VALUE_TMP" 2>&1)" || VALIDATE_CODE=$?
    rm -f "$SCHEMA_TMP" "$VALUE_TMP"
    if [[ "$VALIDATE_CODE" -eq 1 ]]; then
        STATUS="failed"
        REASON="schema validation failed: ${VALIDATE_ERR}"
    fi
    # exit 2 (validator unavailable) → pass through unchanged
fi

# Build envelope
jq -n \
    --arg status "$STATUS" \
    --argjson value "$VALUE_JSON" \
    --arg reason "$REASON" \
    --arg cq "$CLARIFYING_QUESTION" \
    --argjson input_tokens "$INPUT_TOKENS" \
    --argjson output_tokens "$OUTPUT_TOKENS" \
    --argjson cache_read "$CACHE_READ" \
    --argjson cache_creation "$CACHE_CREATION" \
    --argjson cost_usd "$COST_USD" \
    --argjson latency_ms "$LATENCY_MS" \
    --arg model "$MODEL" \
    --argjson num_turns "$NUM_TURNS" \
    '{
        result: {
            status: $status,
            value: $value,
            reason: (if $reason == "" then null else $reason end),
            clarifying_question: (if $cq == "" then null else $cq end),
            retry_meta: null
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
        harness: "pi"
    }'
exit 0
