#!/usr/bin/env bash
# harnesses/claude/call-dispatch.sh — one-shot claude LLM call dispatch for codegen-call.
#
# Called by codegen-call via exec after env vars are set.
# Captures claude stream-json output, parses it into a normalized JSON envelope,
# emits the envelope on stdout.
# STDOUT: one JSON envelope object. STDERR: diagnostics only.
#
# CODEGEN_CALL_TRANSCRIPT_PATH is OPTIONAL — when set, the temp stream-json is
# copied there before deletion; unset → no transcript (one-shot codegen-call
# unaffected).

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
AGENT="${CODEGEN_CALL_AGENT:-}"
RESUME="${CODEGEN_CALL_RESUME:-}"
SESSION_ID_ARG="${CODEGEN_CALL_SESSION_ID:-}"
MODEL="${CODEGEN_CALL_MODEL:?CODEGEN_CALL_MODEL not set}"
EFFORT="${CODEGEN_CALL_EFFORT:?CODEGEN_CALL_EFFORT not set}"
PROMPT="${CODEGEN_CALL_PROMPT:?CODEGEN_CALL_PROMPT not set}"
JSON_SCHEMA_PATH="${CODEGEN_CALL_JSON_SCHEMA_PATH:-}"
JSON_SCHEMA_CONTENT="${CODEGEN_CALL_JSON_SCHEMA:-}"
ALLOWED_TOOLS="${CODEGEN_CALL_ALLOWED_TOOLS:-}"
ALLOWED_TOOLS_SET="${CODEGEN_CALL_ALLOWED_TOOLS_SET:-}"
SETTINGS_PATH="${CODEGEN_CALL_SETTINGS_PATH:-}"
AGENTS_PATH="${CODEGEN_CALL_AGENTS_PATH:-}"
PRINT_ARGV="${CODEGEN_CALL_PRINT_ARGV:-}"

# --system-prompt is required UNLESS --agent is set (agent supplies identity
# natively via `claude --agent <role>`; codegen-call waives the requirement).
if [[ -z "$AGENT" ]]; then
    SYSTEM_PROMPT="${CODEGEN_CALL_SYSTEM_PROMPT:?CODEGEN_CALL_SYSTEM_PROMPT not set}"
else
    SYSTEM_PROMPT="${CODEGEN_CALL_SYSTEM_PROMPT:-}"
fi

_capture_transcript() {
    [ -n "${CODEGEN_CALL_TRANSCRIPT_PATH:-}" ] || return 0
    [ -n "${TMP_OUT:-}" ] && [ -f "$TMP_OUT" ] || return 0
    local dest="$CODEGEN_CALL_TRANSCRIPT_PATH"
    if ! mkdir -p "$(dirname "$dest")" 2>/dev/null || ! cp "$TMP_OUT" "$dest" 2>/dev/null; then
        printf 'codegen-call: transcript copy failed: could not write %s\n' "$dest" >&2
    fi
}

# --setting-sources: user-scope (~/.claude/agents/) is where role agents
# install; a loop-invoked --agent call needs it. Non-agent one-shot calls
# (e.g. consuming-platform --system-prompt calls) stay project-only (thinking-off scope).
if [[ -n "$AGENT" ]]; then SETTING_SOURCES="user,project"; else SETTING_SOURCES="project"; fi

# ── Build claude argv ─────────────────────────────────────────────────────────
COMMON_FLAGS=(
    --dangerously-skip-permissions
    --print
    --output-format stream-json
    --verbose
    --setting-sources "$SETTING_SOURCES"
    --strict-mcp-config
    --disable-slash-commands
    --model "$MODEL"
    --effort "$EFFORT"
)

# --agent: named-agent identity (native, replaces --append-system-prompt)
if [[ -n "$AGENT" ]]; then
    COMMON_FLAGS+=(--agent "$AGENT")
else
    COMMON_FLAGS+=(--append-system-prompt "$SYSTEM_PROMPT")
fi

# --resume: warm-resume a prior persisted session (sessions persist by
# default now — no opt-out flag disables that). --session-id: pin a NEW
# (cold) call to a caller-minted id, so a future --resume can recover it
# even if this process is killed before it ever reports its own session id.
# Mutually exclusive: --resume wins if a caller mistakenly sets both.
if [[ -n "$RESUME" ]]; then
    COMMON_FLAGS+=(--resume "$RESUME")
elif [[ -n "$SESSION_ID_ARG" ]]; then
    COMMON_FLAGS+=(--session-id "$SESSION_ID_ARG")
fi

# --tools: explicit list wins; no agent + no explicit → hermetic deny-all;
# agent + no explicit → omit flag so agent frontmatter tools: apply.
if [[ -n "$ALLOWED_TOOLS_SET" ]]; then
    COMMON_FLAGS+=(--tools "$ALLOWED_TOOLS")
elif [[ -z "$AGENT" ]]; then
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

# --agents: inline agent-def JSON, passed through verbatim; this script never
# opens, parses, or names the agents the JSON carries (mirrors --settings /
# --extension passthrough discipline).
if [[ -n "$AGENTS_PATH" ]]; then
    COMMON_FLAGS+=(--agents "$(cat "$AGENTS_PATH")")
fi

# --print-argv: dry-run — print the fully-built argv (one per line) and exit
# 0 without invoking claude. Lets an external consumer assert its exact argv
# against this contract at CI speed, with no LLM spend.
if [[ -n "$PRINT_ARGV" ]]; then
    printf '%s\n' "${COMMON_FLAGS[@]}" -- "$PROMPT"
    exit 0
fi

# ── Capture claude output ─────────────────────────────────────────────────────
TMP_OUT="$(mktemp -t codegen-call-claude.XXXXXX.jsonl)"
trap '_capture_transcript; rm -f "$TMP_OUT"' EXIT

START_TS_MS="$(_ts_ms)"

# ── Idle/stall watchdog (loop-invoked calls only, CODEGEN_LOOP=1) ────────────
# A dropped/stalled API connection can leave claude emitting its full response
# then never exiting (S+/sleeping on a stalled ESTABLISHED socket). System.cmd
# in the Elixir loop has no timeout, so a hung claude wedges the whole build
# indefinitely. The watchdog kills a hung child on either of two triggers:
#   (1) result-present fast-path: TMP_OUT already carries a terminal "result"
#       event AND the process is still alive after CODEGEN_CALL_RESULT_GRACE_SECS
#       (default 30s) — the work is done; recover it as a salvaged success.
#   (2) idle cap: TMP_OUT has not grown for CODEGEN_CALL_IDLE_CAP_SECS (default
#       900s) — a genuine mid-stream stall with no result to salvage.
# One-shot platform codegen-call (no CODEGEN_LOOP) runs the exec verbatim,
# uncapped — byte-identical to pre-watchdog behavior.
WATCHDOG_KILLED=""
if [[ "${CODEGEN_LOOP:-}" == "1" ]]; then
    RESULT_GRACE_SECS="${CODEGEN_CALL_RESULT_GRACE_SECS:-30}"
    IDLE_CAP_SECS="${CODEGEN_CALL_IDLE_CAP_SECS:-900}"

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
        claude "${COMMON_FLAGS[@]}" -- "$PROMPT" </dev/null >"$TMP_OUT" 2>&1 &
    CHILD_PID=$!

    LAST_SIZE=-1
    LAST_GROWTH_TS=$(_ts_ms)
    RESULT_SEEN_TS=""
    while kill -0 "$CHILD_PID" 2>/dev/null; do
        sleep 5
        CUR_SIZE="$(wc -c <"$TMP_OUT" 2>/dev/null || printf '0')"
        NOW_MS=$(_ts_ms)
        if [[ "$CUR_SIZE" != "$LAST_SIZE" ]]; then
            LAST_SIZE="$CUR_SIZE"
            LAST_GROWTH_TS="$NOW_MS"
        fi

        # Trigger (1): terminal result event already present.
        if [[ -z "$RESULT_SEEN_TS" ]]; then
            if jq -c -R 'fromjson? | select(.type == "result")' "$TMP_OUT" 2>/dev/null | grep -q .; then
                RESULT_SEEN_TS="$NOW_MS"
            fi
        fi
        if [[ -n "$RESULT_SEEN_TS" ]] && (((NOW_MS - RESULT_SEEN_TS) / 1000 >= RESULT_GRACE_SECS)); then
            printf 'codegen-call: watchdog killing claude (pid %s) — result already emitted, grace %ss elapsed\n' "$CHILD_PID" "$RESULT_GRACE_SECS" >&2
            WATCHDOG_KILLED=1
            break
        fi

        # Trigger (2): idle cap — no output growth for IDLE_CAP_SECS.
        if (((NOW_MS - LAST_GROWTH_TS) / 1000 >= IDLE_CAP_SECS)); then
            printf 'codegen-call: watchdog killing claude (pid %s) — idle %ss with no output growth\n' "$CHILD_PID" "$IDLE_CAP_SECS" >&2
            WATCHDOG_KILLED=1
            break
        fi
    done

    if [[ -n "$WATCHDOG_KILLED" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$CHILD_PID" 2>/dev/null || true
        pkill -9 -P "$CHILD_PID" 2>/dev/null || true
    fi

    wait "$CHILD_PID"
    EXIT_CODE=$?
    set -e
else
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
        claude "${COMMON_FLAGS[@]}" -- "$PROMPT" </dev/null >"$TMP_OUT" 2>&1
    EXIT_CODE=$?
    set -e
fi

END_TS_MS="$(_ts_ms)"
LATENCY_MS=$((END_TS_MS - START_TS_MS))

# ── Parse stream-json into envelope ──────────────────────────────────────────
# Extract the last result event from stream-json
RESULT_EVENT="$(jq -c -R 'fromjson? | select(.type == "result")' "$TMP_OUT" 2>/dev/null | tail -1 || true)"

# ── Summarize tool-trace metrics (assistant tool_use / user tool_result) ────
# TMP_OUT already carries the FULL stream-json trace (every assistant/user
# event with tool_use/tool_result content); today the envelope discards it
# once RESULT_EVENT is extracted above. One extra jq pass over the same
# on-disk temp file folds it into a compact `metrics` block — no new claude
# invocation, no second model pass. Fields the stream cannot supply (e.g.
# stop_reason/rate_limited when the source events are absent) are OMITTED,
# never defaulted to a fake zero/false — a faked datum is exactly the
# green-on-empty defect this exists to fix. Only attached to the SUCCESS
# envelope below (see STATUS gate) — a failure/watchdog/no-result path has no
# trustworthy trace to summarize.
_summarize_metrics() {
    jq -c -R 'fromjson?' "$TMP_OUT" 2>/dev/null | jq -s '
        . as $all
        | ($all | map(select(.type == "assistant"))) as $asst
        | ($asst
            | map({parent: .parent_tool_use_id, tu: (.message.content[]? | select(.type == "tool_use"))})
          ) as $tool_uses
        | ($tool_uses | map(select(.parent == null) | .tu)) as $top_tus
        | ($top_tus | map(select(.name == "Read")) | length) as $read_count
        | ($top_tus | map(select(.name == "Edit" or .name == "MultiEdit")) | length) as $edit_count
        | ($top_tus | map(select(.name == "Write")) | length) as $write_count
        | ($top_tus | map(select(.name == "Bash")) | length) as $bash_count
        | ($top_tus | group_by(.name) | map({key: .[0].name, value: length}) | from_entries) as $tool_counts
        | ($tool_uses | map(select(.parent != null))) as $sub_tus
        | ($asst
            | map(.message.content[]? | select(.type == "tool_use" and .name == "Agent"))
            | map({(.id): .input.subagent_type})
            | add // {}
          ) as $agent_id_to_type
        | (
            $sub_tus
            | map(. + {subagent_type: ($agent_id_to_type[.parent] // "unknown")})
            | group_by(.subagent_type)
            | map({
                key: .[0].subagent_type,
                value: {
                    read_count: (map(select(.tu.name == "Read")) | length),
                    edit_count: (map(select(.tu.name == "Edit" or .tu.name == "MultiEdit")) | length),
                    write_count: (map(select(.tu.name == "Write")) | length),
                    bash_count: (map(select(.tu.name == "Bash")) | length)
                }
              })
            | from_entries
          ) as $per_subagent
        | ($all | map(select(.type == "result")) | last) as $result_ev
        | ($all | map(select(.type == "rate_limit_event")) | last) as $rl_ev
        | {
            read_count: $read_count,
            edit_count: $edit_count,
            write_count: $write_count,
            bash_count: $bash_count
          }
          + (if ($tool_counts | length) > 0 then {tool_counts: $tool_counts} else {} end)
          + (if ($per_subagent | length) > 0 then {per_subagent: $per_subagent} else {} end)
          + (if $edit_count > 0 then {read_edit_ratio: ($read_count / $edit_count)} else {} end)
          + (if $result_ev != null and ($result_ev.stop_reason // null) != null then {stop_reason: $result_ev.stop_reason} else {} end)
          + (if $rl_ev != null then {rate_limited: (($rl_ev.rate_limit_info.status // "allowed") != "allowed")} else {} end)
    ' 2>/dev/null || true
}

# Watchdog stall (no salvageable result event) → emit a proper failed envelope
# with a retryable-taxonomy reason and exit 0 (NOT 1) so the loop reads the
# FULL untruncated reason via Jason.decode! rather than synthesizing its own
# reason from only the last 400 chars of stdout (which can truncate the
# "Stream idle timeout" token out of a large raw TMP_OUT tail).
if [[ -n "$WATCHDOG_KILLED" ]] && [[ -z "$RESULT_EVENT" ]]; then
    jq -n \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "Stream idle timeout: claude process did not exit and produced no result event",
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
                num_turns: null
            },
            error: "watchdog: Stream idle timeout",
            harness: "claude_code",
            session_id: null
        }'
    exit 0
fi

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
                num_turns: null
            },
            error: $error,
            harness: "claude_code",
            session_id: null
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
                num_turns: null
            },
            error: ("no result event; tail: " + $tail_out),
            harness: "claude_code",
            session_id: null
        }'
    exit 0
fi

# Extract fields from result event
SUBTYPE="$(printf '%s' "$RESULT_EVENT" | jq -r '.subtype // "unknown"')"
IS_ERROR="$(printf '%s' "$RESULT_EVENT" | jq -r '.is_error // false')"
RESULT_TEXT="$(printf '%s' "$RESULT_EVENT" | jq -r '.result // ""')"
# Null-preserving: absent num_turns/total_cost_usd must record as JSON null,
# never a fabricated "1 turn" / "free" sentinel (masking-default discipline).
NUM_TURNS="$(printf '%s' "$RESULT_EVENT" | jq -c '.num_turns // null')"
TOTAL_COST="$(printf '%s' "$RESULT_EVENT" | jq -c '.total_cost_usd // null')"
SESSION_ID="$(printf '%s' "$RESULT_EVENT" | jq -r '.session_id // ""')"

# Extract usage tokens from result event
INPUT_TOKENS="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.input_tokens // 0')"
OUTPUT_TOKENS="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.output_tokens // 0')"
CACHE_READ="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.cache_read_input_tokens // 0')"
CACHE_CREATION="$(printf '%s' "$RESULT_EVENT" | jq -r '.usage.cache_creation_input_tokens // 0')"

# Model-vs-local split + hook-denial + cache signals — already present on the
# result event today, previously unlifted (see pitch
# "build-cycle-accounts-for-its-own-time" Move 2). Absent → JSON null, never
# a fabricated zero.
DURATION_MS="$(printf '%s' "$RESULT_EVENT" | jq -c '.duration_ms // null')"
DURATION_API_MS="$(printf '%s' "$RESULT_EVENT" | jq -c '.duration_api_ms // null')"
TTFT_MS="$(printf '%s' "$RESULT_EVENT" | jq -c '.ttft_ms // null')"
PERMISSION_DENIALS_COUNT="$(printf '%s' "$RESULT_EVENT" | jq -c '(.permission_denials // null) | if . == null then null else length end')"
STOP_REASON="$(printf '%s' "$RESULT_EVENT" | jq -c '.stop_reason // null')"

# Determine status
STATUS=""
REASON=""
RETRY_META="null"

if [[ "$SUBTYPE" == "error_max_structured_output_retries" ]]; then
    STATUS="schema_retry_exhausted"
    REASON="$(printf '%s' "$RESULT_EVENT" | jq -r '.message // "max structured output retries exceeded"')"
    # Build retry_meta from result event
    RETRY_META="$(printf '%s' "$RESULT_EVENT" | jq -c '{retries: (.num_retries // 3), last_error: (.message // "max retries exceeded")}')"
elif [[ "$IS_ERROR" == "true" ]]; then
    STATUS="failed"
    # .errors[0] first: a resume against a nonexistent session reports its
    # cause there (e.g. "No conversation found with session ID: <id>") —
    # .message/.result are absent on that path, so the old fallback order
    # collapsed to the useless literal "error".
    REASON="$(printf '%s' "$RESULT_EVENT" | jq -r '.errors[0] // .message // .result // "error"')"
elif [[ "$SUBTYPE" == "success" ]]; then
    STATUS="success"
else
    STATUS="failed"
    REASON="unexpected result subtype: $SUBTYPE"
fi

# Tool-trace metrics — success only. A failed/schema-exhausted call's trace is
# not trustworthy evidence of a normal run; omit rather than emit a metrics
# block that reads as real data for an abnormal call.
METRICS="null"
if [[ "$STATUS" == "success" ]]; then
    METRICS="$(_summarize_metrics)"
    [[ -z "$METRICS" ]] && METRICS="null"
fi

# Extract structured value
# If json-schema was requested, try to find JSON in the assistant message
VALUE_JSON="null"
if [[ -n "$JSON_SCHEMA_CONTENT" ]] && [[ "$STATUS" == "success" || "$STATUS" == "schema_retry_exhausted" ]]; then
    # Prefer structured_output from the result event (StructuredOutput tool path)
    SO_JSON="$(printf '%s' "$RESULT_EVENT" | jq -c '.structured_output // empty' 2>/dev/null || true)"
    if [[ -n "$SO_JSON" ]] && [[ "$SO_JSON" != "null" ]]; then
        VALUE_JSON="$SO_JSON"
    fi
    if [[ "$VALUE_JSON" == "null" ]]; then
        # Fall back: search for last assistant message with parseable JSON content
        LAST_ASSISTANT_JSON="$(
            jq -c -R 'fromjson? | select(.type == "assistant") |
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
    fi
elif [[ "$STATUS" == "success" ]]; then
    VALUE_JSON="$(printf '%s' "$RESULT_TEXT" | jq -Rs '.')"
elif [[ -n "$RESULT_TEXT" ]]; then
    VALUE_JSON="$(printf '%s' "$RESULT_TEXT" | jq -Rs '.')"
fi

# ── Schema validation (only when a schema was requested and call succeeded) ──
if [[ -n "$JSON_SCHEMA_CONTENT" ]] && [[ "$STATUS" == "success" ]] && [[ "$VALUE_JSON" != "null" ]]; then
    SCHEMA_TMP="$(mktemp -t codegen-call-schema.XXXXXX.json)"
    VALUE_TMP="$(mktemp -t codegen-call-value.XXXXXX.json)"
    printf '%s' "$JSON_SCHEMA_CONTENT" >"$SCHEMA_TMP"
    printf '%s' "$VALUE_JSON" >"$VALUE_TMP"
    VALIDATE_ERR=""
    VALIDATE_CODE=0
    VALIDATE_ERR="$(node "$(dirname "${BASH_SOURCE[0]}")/hooks/lib/schema-validate.js" "$SCHEMA_TMP" "$VALUE_TMP" 2>&1)" || VALIDATE_CODE=$?
    rm -f "$SCHEMA_TMP" "$VALUE_TMP"
    if [[ "$VALIDATE_CODE" -eq 1 ]]; then
        STATUS="failed"
        REASON="schema validation failed: ${VALIDATE_ERR}"
        METRICS="null"
    elif [[ "$VALIDATE_CODE" -eq 2 ]]; then
        STATUS="failed"
        REASON="schema validator unavailable (ajv not resolvable) — cannot verify structured output; run npm install in codegen"
        METRICS="null"
    fi
fi

# Build envelope
jq -n \
    --arg status "$STATUS" \
    --argjson value "$VALUE_JSON" \
    --arg reason "$REASON" \
    --argjson retry_meta "$RETRY_META" \
    --argjson input_tokens "$INPUT_TOKENS" \
    --argjson output_tokens "$OUTPUT_TOKENS" \
    --argjson cache_read "$CACHE_READ" \
    --argjson cache_creation "$CACHE_CREATION" \
    --argjson cost_usd "$TOTAL_COST" \
    --argjson latency_ms "$LATENCY_MS" \
    --arg model "$MODEL" \
    --argjson num_turns "$NUM_TURNS" \
    --arg session_id "$SESSION_ID" \
    --argjson metrics "$METRICS" \
    --argjson duration_ms "$DURATION_MS" \
    --argjson duration_api_ms "$DURATION_API_MS" \
    --argjson ttft_ms "$TTFT_MS" \
    --argjson permission_denials "$PERMISSION_DENIALS_COUNT" \
    --argjson stop_reason "$STOP_REASON" \
    '{
        result: {
            status: $status,
            value: $value,
            reason: (if $reason == "" then null else $reason end),
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
            num_turns: $num_turns,
            duration_ms: $duration_ms,
            duration_api_ms: $duration_api_ms,
            ttft_ms: $ttft_ms,
            permission_denials: $permission_denials,
            stop_reason: $stop_reason
        },
        error: null,
        harness: "claude_code",
        session_id: (if $session_id == "" then null else $session_id end)
    }
    + (if $metrics == null then {} else {metrics: $metrics} end)'
exit 0
