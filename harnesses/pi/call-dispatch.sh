#!/usr/bin/env bash
# harnesses/pi/call-dispatch.sh — one-shot pi LLM call dispatch for codegen-call.
#
# Called by codegen-call via exec after env vars are set.
# Captures pi JSONL output, parses agent_end events into a normalized JSON envelope,
# emits the envelope on stdout.
# STDOUT: one JSON envelope object. STDERR: diagnostics only.
#
# CODEGEN_CALL_TRANSCRIPT_PATH is OPTIONAL — when set, the temp stream-json is
# copied there before deletion; unset → no transcript (one-shot codegen-call
# unaffected).

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
AGENT="${CODEGEN_CALL_AGENT:-}"
MODEL="${CODEGEN_CALL_MODEL:?CODEGEN_CALL_MODEL not set}"
EFFORT="${CODEGEN_CALL_EFFORT:?CODEGEN_CALL_EFFORT not set}"
PROMPT="${CODEGEN_CALL_PROMPT:?CODEGEN_CALL_PROMPT not set}"
JSON_SCHEMA_CONTENT="${CODEGEN_CALL_JSON_SCHEMA:-}"
EXTENSION_PATH="${CODEGEN_CALL_EXTENSION_PATH:-}"
RESUME="${CODEGEN_CALL_RESUME:-}"
SESSION_ID_ARG="${CODEGEN_CALL_SESSION_ID:-}"
PRINT_ARGV="${CODEGEN_CALL_PRINT_ARGV:-}"
# CODEGEN_CALL_AGENTS_PATH is claude-only (inline agent-def JSON); pi has no
# native inline-agent-def concept and ignores it — accepted, never forwarded.
# Pi's identity path stays fail-closed independently (see SYSTEM_PROMPT
# required-unless-AGENT check above/below); silently dropping --agents here
# can never yield an identity-less call.

# --system-prompt is required UNLESS --agent is set (agent supplies identity
# natively via the resolved agent-definition body; codegen-call waives the
# requirement — mirrors harnesses/claude/call-dispatch.sh).
if [[ -z "$AGENT" ]]; then
    SYSTEM_PROMPT="${CODEGEN_CALL_SYSTEM_PROMPT:?CODEGEN_CALL_SYSTEM_PROMPT not set}"
else
    SYSTEM_PROMPT="${CODEGEN_CALL_SYSTEM_PROMPT:-}"
fi

# ── Resolve a named-agent's prompt body from its installed .md definition ────
# Pi has no native --agent flag; identity is --system-prompt (REPLACE) + the
# AGENT_TYPE env var the enforcement extension reads. agents_dir mirrors
# harnesses/pi/manifest.yaml's `agents_dir: ~/.pi/agent/agents`; the
# repo-relative templates/generated/pi/agent/ dir is the pre-install fallback.
#
# Agent .md files now carry YAML frontmatter (name/description/model/tools —
# rendered via config.yaml tools.pi.tool_map, already in pi vocabulary; a
# frontmatter-less legacy file is still supported below). --system-prompt
# must receive the BODY ONLY — leaking the raw frontmatter into the prompt
# would corrupt every pi role's system prompt. Sets
# MODULE-SCOPE AGENT_BODY and AGENT_TOOLS (read by the argv-build block below).
AGENT_BODY=""
AGENT_TOOLS=""
_resolve_pi_agent() {
    local role="$1"
    local script_dir installed_dir generated_dir agent_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    installed_dir="$HOME/.pi/agent/agents"
    generated_dir="$(cd "$script_dir/../.." && pwd -P)/templates/generated/pi/agent"

    for agent_file in "$installed_dir/$role.md" "$generated_dir/$role.md"; do
        if [[ -f "$agent_file" ]]; then
            if [[ "$(head -n 1 "$agent_file")" == "---" ]]; then
                # Frontmatter present: body = everything after the closing ---.
                # n>=2 guard so a literal '---' horizontal rule inside the
                # body is printed, not treated as a second delimiter.
                AGENT_TOOLS="$(awk '/^---$/{n++; if(n==2) exit; next} n==1 && /^tools:[[:space:]]*/{sub(/^tools:[[:space:]]*/,""); print; exit}' "$agent_file")"
                AGENT_BODY="$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$agent_file")"
            else
                # Legacy frontmatter-less agent: whole file is the identity.
                AGENT_BODY="$(cat "$agent_file")"
                AGENT_TOOLS=""
            fi
            return 0
        fi
    done

    printf 'codegen-call (pi): agent definition not found: %s/%s.md\n' "$installed_dir" "$role" >&2
    return 2
}

if [[ -n "$AGENT" ]]; then
    _resolve_pi_agent "$AGENT"
    SYSTEM_PROMPT="$AGENT_BODY"
    # Native identity signal for the enforcement extension (pi analogue of the
    # `.agent_type` claude stamps into hook payloads natively).
    export AGENT_TYPE="$AGENT"
fi

_capture_transcript() {
    [ -n "${CODEGEN_CALL_TRANSCRIPT_PATH:-}" ] || return 0
    [ -n "${TMP_OUT:-}" ] && [ -f "$TMP_OUT" ] || return 0
    local dest="$CODEGEN_CALL_TRANSCRIPT_PATH"
    if ! mkdir -p "$(dirname "$dest")" 2>/dev/null || ! cp "$TMP_OUT" "$dest" 2>/dev/null; then
        printf 'codegen-call: transcript copy failed: could not write %s\n' "$dest" >&2
    fi
}

# ── Build prompt (embed JSON schema as instruction if provided) ───────────────
EFFECTIVE_PROMPT="$PROMPT"
if [[ -n "$JSON_SCHEMA_CONTENT" ]]; then
    EFFECTIVE_PROMPT="${PROMPT}

Respond with valid JSON matching this schema:
${JSON_SCHEMA_CONTENT}"
fi

# ── Build pi argv ─────────────────────────────────────────────────────────────
# --system-prompt REPLACES pi's default coding-assistant prompt (matches
# codegen-call's whole-identity REPLACE contract for both agent and one-shot
# system-prompt calls — see harnesses/claude/call-dispatch.sh's --agent leg).
ARGS=(
    -p
    --mode json
    --no-context-files
    --system-prompt "$SYSTEM_PROMPT"
    --provider openai-codex
    --model "$MODEL"
    --thinking "$EFFORT"
)

# --session-id resumes/creates a specific persisted session (pi's closest
# equivalent to claude's --resume). A loop-shaped agent call with no RESUME
# still needs an id so the envelope can echo one back for warm-resume
# (pi's --session-id creates the session if missing — see `pi --help`).
# A bare one-shot call (no --agent) stays ephemeral: --no-session.
#
# Precedence: RESUME (warm-resume an existing session) > SESSION_ID_ARG (a
# caller-minted id for a COLD call, pinned up front so a later --resume can
# recover it) > AGENT (self-minted id, legacy loop path) > ephemeral.
MINTED_SESSION_ID=""
if [[ -n "$RESUME" ]]; then
    ARGS+=(--session-id "$RESUME")
elif [[ -n "$SESSION_ID_ARG" ]]; then
    ARGS+=(--session-id "$SESSION_ID_ARG")
elif [[ -n "$AGENT" ]]; then
    if command -v uuidgen >/dev/null 2>&1; then
        MINTED_SESSION_ID="$(uuidgen)"
    else
        MINTED_SESSION_ID="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    fi
    ARGS+=(--session-id "$MINTED_SESSION_ID")
else
    ARGS+=(--no-session)
fi

# --tools: explicit --allowed-tools wins; otherwise the agent's frontmatter
# tools: (already in pi vocabulary — translated at generate time via
# config.yaml tools.pi.tool_map). No agent + no explicit → omit (pi default).
ALLOWED_TOOLS="${CODEGEN_CALL_ALLOWED_TOOLS:-}"
ALLOWED_TOOLS_SET="${CODEGEN_CALL_ALLOWED_TOOLS_SET:-}"
if [[ -n "$ALLOWED_TOOLS_SET" ]]; then
    ARGS+=(--tools "$ALLOWED_TOOLS")
elif [[ -n "$AGENT_TOOLS" ]]; then
    ARGS+=(--tools "$AGENT_TOOLS")
fi

if [[ -n "$EXTENSION_PATH" ]]; then
    ARGS+=(--extension "$EXTENSION_PATH")
fi

ARGS+=("$EFFECTIVE_PROMPT")

# --print-argv: dry-run — print the fully-built argv (one per line) and exit
# 0 without invoking pi. Mirrors harnesses/claude/call-dispatch.sh.
if [[ -n "$PRINT_ARGV" ]]; then
    printf '%s\n' "${ARGS[@]}"
    exit 0
fi

# Session id actually in play for this call — threaded into the envelope so
# the loop's retrospective-resume (--resume=<session_id>) can round-trip on
# pi the same way it does on claude. Ephemeral one-shot calls (--no-session)
# carry no session id.
EFFECTIVE_SESSION_ID="$RESUME"
[[ -z "$EFFECTIVE_SESSION_ID" ]] && EFFECTIVE_SESSION_ID="$SESSION_ID_ARG"
[[ -z "$EFFECTIVE_SESSION_ID" ]] && EFFECTIVE_SESSION_ID="$MINTED_SESSION_ID"

# ── Capture pi output ─────────────────────────────────────────────────────────
TMP_OUT="$(mktemp -t codegen-call-pi.XXXXXX.jsonl)"
trap '_capture_transcript; rm -f "$TMP_OUT"' EXIT

START_TS_MS="$(_ts_ms)"

# ── Idle/stall watchdog (loop-invoked calls only, CODEGEN_LOOP=1) ────────────
# Mirrors harnesses/claude/call-dispatch.sh's watchdog: a dropped/stalled API
# connection can leave pi emitting its full response then never exiting.
# System.cmd in the Elixir loop has no timeout, so a hung pi wedges the whole
# build indefinitely. Two kill triggers:
#   (1) result-present fast-path: TMP_OUT already carries a terminal
#       "agent_end" event AND the process is still alive after
#       CODEGEN_CALL_RESULT_GRACE_SECS (default 30s) — salvage as success.
#   (2) idle cap: TMP_OUT has not grown for CODEGEN_CALL_IDLE_CAP_SECS
#       (default 900s) — a genuine mid-stream stall with nothing to salvage.
# One-shot platform codegen-call (no CODEGEN_LOOP) runs the exec verbatim,
# uncapped — byte-identical to pre-watchdog behavior.
WATCHDOG_KILLED=""
if [[ "${CODEGEN_LOOP:-}" == "1" ]]; then
    RESULT_GRACE_SECS="${CODEGEN_CALL_RESULT_GRACE_SECS:-30}"
    IDLE_CAP_SECS="${CODEGEN_CALL_IDLE_CAP_SECS:-900}"

    set +e
    env \
        -u OPENAI_API_KEY \
        -u ANTHROPIC_API_KEY \
        -u CURSOR_API_KEY \
        pi "${ARGS[@]}" </dev/null >"$TMP_OUT" 2>&1 &
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

        # Trigger (1): terminal agent_end event already present.
        if [[ -z "$RESULT_SEEN_TS" ]]; then
            if jq -c 'select(.type == "agent_end")' "$TMP_OUT" 2>/dev/null | grep -q .; then
                RESULT_SEEN_TS="$NOW_MS"
            fi
        fi
        if [[ -n "$RESULT_SEEN_TS" ]] && (((NOW_MS - RESULT_SEEN_TS) / 1000 >= RESULT_GRACE_SECS)); then
            printf 'codegen-call: watchdog killing pi (pid %s) — agent_end already emitted, grace %ss elapsed\n' "$CHILD_PID" "$RESULT_GRACE_SECS" >&2
            WATCHDOG_KILLED=1
            break
        fi

        # Trigger (2): idle cap — no output growth for IDLE_CAP_SECS.
        if (((NOW_MS - LAST_GROWTH_TS) / 1000 >= IDLE_CAP_SECS)); then
            printf 'codegen-call: watchdog killing pi (pid %s) — idle %ss with no output growth\n' "$CHILD_PID" "$IDLE_CAP_SECS" >&2
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
        -u OPENAI_API_KEY \
        -u ANTHROPIC_API_KEY \
        -u CURSOR_API_KEY \
        pi "${ARGS[@]}" </dev/null >"$TMP_OUT" 2>&1
    EXIT_CODE=$?
    set -e
fi

END_TS_MS="$(_ts_ms)"
LATENCY_MS=$((END_TS_MS - START_TS_MS))

# ── Parse JSONL into envelope ─────────────────────────────────────────────────
# Find last agent_end event
AGENT_END_EVENT="$(jq -c 'select(.type == "agent_end")' "$TMP_OUT" 2>/dev/null | tail -1 || true)"

# ── Summarize tool-trace metrics (tool_execution_end events) ────────────────
# pi's event vocabulary differs from claude's (tool_execution_start/_end with
# lowercase toolName, no parent_tool_use_id, no rate_limit_event, and its
# agent_end carries no top-level usage/num_turns — see
# harnesses/claude/call-dispatch.sh for the claude-side summarizer). Fields
# pi's stream cannot supply (rate_limited, per_subagent, stop_reason) are
# OMITTED here, never faked — the schema stays uniform by omission, not by a
# claude-shaped block backfilled with fabricated data. Only attached to the
# SUCCESS envelope below (see STATUS gate).
_summarize_metrics() {
    jq -c '.' "$TMP_OUT" 2>/dev/null | jq -s '
        . as $all
        | ($all | map(select(.type == "tool_execution_end"))) as $ends
        | ($ends | map(select(.toolName == "read")) | length) as $read_count
        | ($ends | map(select(.toolName == "edit" or .toolName == "multiedit")) | length) as $edit_count
        | ($ends | map(select(.toolName == "write")) | length) as $write_count
        | ($ends | map(select(.toolName == "bash")) | length) as $bash_count
        | ($ends | group_by(.toolName) | map({key: .[0].toolName, value: length}) | from_entries) as $tool_counts
        | {
            read_count: $read_count,
            edit_count: $edit_count,
            write_count: $write_count,
            bash_count: $bash_count
          }
          + (if ($tool_counts | length) > 0 then {tool_counts: $tool_counts} else {} end)
          + (if $edit_count > 0 then {read_edit_ratio: ($read_count / $edit_count)} else {} end)
    ' 2>/dev/null || true
}

# Watchdog stall (no salvageable agent_end event) → emit a proper failed
# envelope with a retryable-taxonomy reason and exit 0 (NOT 1) so the loop
# reads the FULL untruncated reason via Jason.decode! rather than
# synthesizing its own reason from only the last 400 chars of stdout.
if [[ -n "$WATCHDOG_KILLED" ]] && [[ -z "$AGENT_END_EVENT" ]]; then
    jq -n \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        --arg session_id "$EFFECTIVE_SESSION_ID" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "Stream idle timeout: pi process did not exit and produced no agent_end event",
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
            harness: "pi",
            session_id: (if $session_id == "" then null else $session_id end)
        }'
    exit 0
fi

if [[ $EXIT_CODE -ne 0 ]] && [[ -z "$AGENT_END_EVENT" ]]; then
    TAIL_OUT="$(tail -c 500 "$TMP_OUT" 2>/dev/null || true)"
    jq -n \
        --arg error "pi exited ${EXIT_CODE}: ${TAIL_OUT}" \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        --arg session_id "$EFFECTIVE_SESSION_ID" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "pi exited non-zero",
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
            harness: "pi",
            session_id: (if $session_id == "" then null else $session_id end)
        }'
    exit 1
fi

if [[ -z "$AGENT_END_EVENT" ]]; then
    TAIL_OUT="$(tail -c 500 "$TMP_OUT" 2>/dev/null || true)"
    jq -n \
        --arg tail_out "$TAIL_OUT" \
        --argjson latency_ms "$LATENCY_MS" \
        --arg model "$MODEL" \
        --arg session_id "$EFFECTIVE_SESSION_ID" \
        '{
            result: {
                status: "failed",
                value: null,
                reason: "no agent_end event found in pi JSONL",
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
            error: ("no agent_end event; tail: " + $tail_out),
            harness: "pi",
            session_id: (if $session_id == "" then null else $session_id end)
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
# Null-preserving: absent num_turns must record as JSON null, never a
# fabricated "1 turn" sentinel (masking-default discipline).
NUM_TURNS="$(printf '%s' "$AGENT_END_EVENT" | jq -c '.num_turns // null' 2>/dev/null || printf 'null')"

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
else
    STATUS="success"
    VALUE_JSON="$(printf '%s' "$ASSISTANT_TEXT" | jq -Rs '.')"
fi

# Tool-trace metrics — success only (mirrors harnesses/claude/call-dispatch.sh).
METRICS="null"
if [[ "$STATUS" == "success" ]]; then
    METRICS="$(_summarize_metrics)"
    [[ -z "$METRICS" ]] && METRICS="null"
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
    --argjson input_tokens "$INPUT_TOKENS" \
    --argjson output_tokens "$OUTPUT_TOKENS" \
    --argjson cache_read "$CACHE_READ" \
    --argjson cache_creation "$CACHE_CREATION" \
    --argjson cost_usd "$COST_USD" \
    --argjson latency_ms "$LATENCY_MS" \
    --arg model "$MODEL" \
    --argjson num_turns "$NUM_TURNS" \
    --arg session_id "$EFFECTIVE_SESSION_ID" \
    --argjson metrics "$METRICS" \
    '{
        result: {
            status: $status,
            value: $value,
            reason: (if $reason == "" then null else $reason end),
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
            num_turns: $num_turns,
            duration_ms: null,
            duration_api_ms: null,
            ttft_ms: null,
            permission_denials: null,
            stop_reason: null
        },
        error: null,
        harness: "pi",
        session_id: (if $session_id == "" then null else $session_id end)
    }
    + (if $metrics == null then {} else {metrics: $metrics} end)'
exit 0
