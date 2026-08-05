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

# Execute immutable bytes. A Pi developer can edit the tracked dispatcher while
# this invocation is still running; Bash otherwise resumes parsing mixed
# old/new source after Pi exits.
if [[ "${CODEGEN_PI_DISPATCH_SNAPSHOT_ACTIVE:-}" != "1" ]]; then
    _dispatch_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    _dispatch_snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/codegen-pi-dispatch.XXXXXX")"
    trap 'rm -rf "$_dispatch_snapshot_dir"' EXIT

    if [[ ! -r "$_dispatch_source_dir/pi-jsonl-filter.cjs" ]]; then
        printf 'codegen-call: Pi stream filter missing or unreadable: %s\n' \
            "$_dispatch_source_dir/pi-jsonl-filter.cjs" >&2
        exit 2
    fi

    if [[ ! -r "$_dispatch_source_dir/../claude/hooks/lib/schema-validate.js" ]]; then
        printf 'codegen-call: schema validator missing or unreadable: %s\n' \
            "$_dispatch_source_dir/../claude/hooks/lib/schema-validate.js" >&2
        exit 2
    fi

    cp "$_dispatch_source_dir/call-dispatch.sh" \
        "$_dispatch_snapshot_dir/call-dispatch.sh"
    cp "$_dispatch_source_dir/pi-jsonl-filter.cjs" \
        "$_dispatch_snapshot_dir/pi-jsonl-filter.cjs"
    cp "$_dispatch_source_dir/../claude/hooks/lib/schema-validate.js" \
        "$_dispatch_snapshot_dir/schema-validate.js"
    chmod +x "$_dispatch_snapshot_dir/call-dispatch.sh"

    export CODEGEN_PI_DISPATCH_SNAPSHOT_ACTIVE=1
    export CODEGEN_PI_DISPATCH_SOURCE_DIR="$_dispatch_source_dir"
    export CODEGEN_PI_DISPATCH_SNAPSHOT_DIR="$_dispatch_snapshot_dir"

    exec /bin/bash "$_dispatch_snapshot_dir/call-dispatch.sh" "$@"
fi

_DISPATCH_SOURCE_DIR="${CODEGEN_PI_DISPATCH_SOURCE_DIR:?missing dispatcher source directory}"
_DISPATCH_SNAPSHOT_DIR="${CODEGEN_PI_DISPATCH_SNAPSHOT_DIR:?missing dispatcher snapshot directory}"

# Snapshot-only vars MUST NOT leak into Pi or nested codegen-call invocations.
unset CODEGEN_PI_DISPATCH_SNAPSHOT_ACTIVE
unset CODEGEN_PI_DISPATCH_SOURCE_DIR
unset CODEGEN_PI_DISPATCH_SNAPSHOT_DIR

_cleanup_dispatch_snapshot() {
    [[ -z "${_DISPATCH_SNAPSHOT_DIR:-}" ]] || rm -rf "$_DISPATCH_SNAPSHOT_DIR"
}

trap '_cleanup_dispatch_snapshot' EXIT

if ! command -v pi >/dev/null 2>&1; then
    printf 'codegen-call (pi): pi binary not found in PATH\n' >&2
    printf 'Install: run '\''make install'\'' in the codegen repo (pins the exact version from harnesses/pi/manifest.yaml)\n' >&2
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
EXTENSION_PATHS="${CODEGEN_CALL_EXTENSION_PATHS:-}"
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
    script_dir="$_DISPATCH_SOURCE_DIR"
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
    --model "$MODEL"
)

# Effort realization (canonical -> native): pi accepts every canonical value
# (including "off") natively via --thinking. An unrecognized value fails
# BEFORE pi ever starts -- never silently drop the control or substitute a
# different value.
case "$EFFORT" in
off | low | medium | high | xhigh | max)
    ARGS+=(--thinking "$EFFORT")
    ;;
*)
    printf 'codegen-call (pi): unsupported effort realization: %s\n' "$EFFORT" >&2
    exit 2
    ;;
esac

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

# Plural paths preserve caller order. Singular fallback keeps installed
# pre-plural codegen-call compatible during staged upgrades.
if [[ -n "$EXTENSION_PATHS" ]]; then
    while IFS= read -r extension_path || [[ -n "$extension_path" ]]; do
        [[ -n "$extension_path" ]] || {
            printf 'codegen-call: invalid empty extension path in CODEGEN_CALL_EXTENSION_PATHS\n' >&2
            exit 2
        }
        ARGS+=(--extension "$extension_path")
    done <<<"$EXTENSION_PATHS"
elif [[ -n "$EXTENSION_PATH" ]]; then
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
TMP_DIR="$(mktemp -d -t codegen-call-pi.XXXXXX)"
PI_PID_FILE="$TMP_DIR/pi.pid"
PI_PROCESS_PID_FILE="$TMP_DIR/pi-process.pid"
PI_STATUS="$TMP_DIR/pi.status"
FILTER_ERR="$TMP_DIR/pi-filter.err"
FILTER_STATUS="$TMP_DIR/pi-filter.status"
FILTER_SCRIPT="$_DISPATCH_SNAPSHOT_DIR/pi-jsonl-filter.cjs"

if [[ ! -r "$FILTER_SCRIPT" ]]; then
    printf 'codegen-call: Pi stream filter missing or unreadable: %s\n' "$FILTER_SCRIPT" >&2
    exit 2
fi

trap '_capture_transcript; rm -f "$TMP_OUT"; rm -rf "$TMP_DIR"; _cleanup_dispatch_snapshot' EXIT

START_TS_MS="$(_ts_ms)"

_start_stream() {
    # Pi can leave grandchildren (notably shell tools) alive after its leader
    # dies. Start it as a session/process-group leader so watchdog cleanup can
    # close every inherited pipe FD before waiting for the filter.
    perl -MPOSIX=setsid -e '
        $pid_file = shift @ARGV;
        setsid() or die "codegen-call: cannot create Pi process session: $!\n";
        open my $fh, ">", $pid_file or die "codegen-call: cannot write Pi pid file: $!\n";
        print {$fh} "$$\n";
        close $fh or die "codegen-call: cannot close Pi pid file: $!\n";
        exec @ARGV or die "codegen-call: cannot exec Pi supervisor: $!\n";
    ' "$PI_PID_FILE" sh -c '
        status_file="$1"
        pi_pid_file="$2"
        shift 2

        "$@" &
        pi_pid=$!
        printf "%s\n" "$pi_pid" >"$pi_pid_file"

        wait "$pi_pid"
        code=$?
        printf "%s\n" "$code" >"$status_file"
        exit "$code"
    ' sh "$PI_STATUS" "$PI_PROCESS_PID_FILE" env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u CURSOR_API_KEY \
        pi "${ARGS[@]}" </dev/null 2>&1 | {
        set +e
        node "$FILTER_SCRIPT" >"$TMP_OUT" 2>"$FILTER_ERR"
        filter_code=$?
        printf "%s\n" "$filter_code" >"$FILTER_STATUS"
        exit 0
    } &
    FILTER_PID=$!

    while [[ ! -s "$PI_PID_FILE" ]] || [[ ! -s "$PI_PROCESS_PID_FILE" ]]; do
        if ! kill -0 "$FILTER_PID" 2>/dev/null; then
            printf 'codegen-call: Pi stream filter exited before process setup\n' >&2
            _cleanup_live_stream
            exit 1
        fi
        sleep 0.05
    done
    CHILD_PID="$(<"$PI_PID_FILE")"
    PI_PROCESS_PID="$(<"$PI_PROCESS_PID_FILE")"
}

_terminate_stream() {
    # CHILD_PID is session leader created by _start_stream. Negative PID
    # signals its process group, preventing orphaned descendants retaining the
    # pipe write end and wedging the filter's EOF drain.
    kill -TERM -- "-$CHILD_PID" 2>/dev/null || true
    sleep 2
    kill -KILL -- "-$CHILD_PID" 2>/dev/null || true
}

_cleanup_live_stream() {
    [[ "${STREAM_FINISHED:-}" == "1" ]] && return 0

    # Filter startup can fail while the supervisor is still publishing its
    # process-group PID. Give that bounded setup write a chance to land so the
    # producer cannot escape cleanup.
    if [[ -z "${CHILD_PID:-}" ]] && [[ -n "${PI_PID_FILE:-}" ]]; then
        for _ in $(seq 1 20); do
            [[ -s "$PI_PID_FILE" ]] && break
            sleep 0.01
        done
        [[ -s "$PI_PID_FILE" ]] && CHILD_PID="$(<"$PI_PID_FILE")"
    fi

    if [[ -n "${CHILD_PID:-}" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        _terminate_stream
    fi

    if [[ -n "${FILTER_PID:-}" ]]; then
        wait "$FILTER_PID" 2>/dev/null || true
    fi

    STREAM_FINISHED=1
}

# Backstop every post-start error path. Normal completion stamps
# STREAM_FINISHED=1 before exit, making this a no-op.
trap '_cleanup_live_stream; _capture_transcript; rm -f "$TMP_OUT"; rm -rf "$TMP_DIR"; _cleanup_dispatch_snapshot' EXIT

_wait_stream() {
    # `wait $FILTER_PID` can wait for the complete pipeline, not only its last
    # process. A silent producer then holds EOF forever after filter exit. Poll
    # owned status files first; filter completion before producer status means
    # the producer must be terminated before pipeline wait/reap.
    while [[ ! -s "$FILTER_STATUS" ]] && [[ ! -s "$PI_STATUS" ]] && kill -0 "$CHILD_PID" 2>/dev/null; do
        sleep 0.05
    done

    FILTER_ENDED_EARLY=""
    if [[ -s "$FILTER_STATUS" ]] && [[ ! -s "$PI_STATUS" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        FILTER_ENDED_EARLY=1
        _terminate_stream
    fi

    # Pi can exit while a tool descendant retains stdout. Give the filter its
    # normal short EOF grace, then terminate the owned process group so wait
    # cannot wedge forever on the descendant's inherited FD.
    if [[ -s "$PI_STATUS" ]] && [[ ! -s "$FILTER_STATUS" ]]; then
        for _ in $(seq 1 20); do
            [[ -s "$FILTER_STATUS" ]] && break
            sleep 0.1
        done

        if [[ ! -s "$FILTER_STATUS" ]] && kill -0 -- "-$CHILD_PID" 2>/dev/null; then
            _terminate_stream
        fi
    fi

    set +e
    wait "$FILTER_PID"
    PIPE_EXIT_CODE=$?
    set -e

    if [[ ! -s "$FILTER_STATUS" ]]; then
        printf 'codegen-call: Pi stream filter exited without a status (pipeline exit %s)\n' "$PIPE_EXIT_CODE" >&2
        _cleanup_live_stream
        exit 1
    fi
    FILTER_EXIT_CODE="$(<"$FILTER_STATUS")"
    if [[ "$FILTER_EXIT_CODE" -ne 0 ]]; then
        FILTER_DETAIL="$(<"$FILTER_ERR")"
        printf 'codegen-call: Pi stream filter failed (exit %s): %s\n' "$FILTER_EXIT_CODE" "$FILTER_DETAIL" >&2
        _cleanup_live_stream
        exit 1
    fi
    if [[ -n "$FILTER_ENDED_EARLY" ]]; then
        printf 'codegen-call: Pi stream filter exited before producer completion\n' >&2
        _cleanup_live_stream
        exit 1
    fi

    if [[ -s "$PI_STATUS" ]]; then
        EXIT_CODE="$(<"$PI_STATUS")"
    elif [[ -n "$WATCHDOG_KILLED" ]]; then
        EXIT_CODE=143
    else
        printf 'codegen-call: Pi supervisor exited without a status\n' >&2
        _cleanup_live_stream
        exit 1
    fi

    STREAM_FINISHED=1
}

# ── Idle/stall watchdog (loop-invoked calls only, CODEGEN_LOOP=1) ────────────
# The stream also preserves non-JSON diagnostics. Never identify lifecycle
# events with a byte grep: stderr can quote a JSON-shaped event name.
_has_terminal_agent_end() {
    jq -e -R 'fromjson? | select(.type == "agent_end")' "$TMP_OUT" >/dev/null 2>&1
}

_post_result_threshold_compaction() {
    jq -e -R -n '
        reduce inputs as $line (
            {terminal: false, post_result_compaction: false};
            (try ($line | fromjson) catch null) as $event
            | if $event.type == "agent_end" then
                .terminal = true
              elif .terminal and $event.type == "compaction_start" and $event.reason == "threshold" then
                .post_result_compaction = true
              else
                .
              end
        )
        | .post_result_compaction
    ' "$TMP_OUT" >/dev/null 2>&1
}

# Mirrors harnesses/claude/call-dispatch.sh's watchdog: a dropped/stalled API
# connection can leave pi emitting its full response then never exiting.
# System.cmd in the Elixir loop has no timeout, so a hung pi wedges the whole
# build indefinitely. Three kill triggers:
#   (1) result-present fast-path: TMP_OUT already carries a terminal
#       "agent_end" event AND the process is still alive after
#       CODEGEN_CALL_RESULT_GRACE_SECS (default 30s) — salvage as success.
#   (2) idle cap: TMP_OUT has not grown for CODEGEN_CALL_IDLE_CAP_SECS
#       (default 900s) — a genuine mid-stream stall with nothing to salvage.
#   (3) dead-stream cap: no output growth for CODEGEN_CALL_STREAM_IDLE_SECS
#       (default 300s) AND no live tool subprocess (pgrep -P empty) — detects a
#       dead socket fast without false-killing a role legitimately silent for
#       minutes while a bash tool (e.g. make test) runs. 300s (not 60s) because
#       a large cached context (e.g. developer-phoenix-backend at ~10M cache_read_tokens)
#       routinely exceeds 60s of server-side first-token latency with no tool
#       subprocess running — a slow turn is not a dead stream. The 900s
#       IDLE_CAP_SECS remains the genuine-stall backstop either way.
# One-shot platform codegen-call (no CODEGEN_LOOP) runs the exec verbatim,
# uncapped — byte-identical to pre-watchdog behavior.
WATCHDOG_KILLED=""
if [[ "${CODEGEN_LOOP:-}" == "1" ]]; then
    RESULT_GRACE_SECS="${CODEGEN_CALL_RESULT_GRACE_SECS:-30}"
    IDLE_CAP_SECS="${CODEGEN_CALL_IDLE_CAP_SECS:-900}"
    STREAM_IDLE_SECS="${CODEGEN_CALL_STREAM_IDLE_SECS:-300}"
    POLL_SECS="${CODEGEN_CALL_POLL_SECS:-5}"

    _start_stream

    LAST_SIZE=-1
    LAST_GROWTH_TS=$(_ts_ms)
    RESULT_SEEN_TS=""
    while kill -0 "$CHILD_PID" 2>/dev/null; do
        sleep "$POLL_SECS"
        # Filter owns its status marker. If it exits while Pi has not reported
        # completion, leave the watchdog loop immediately; _wait_stream kills
        # the producer before waiting for pipeline EOF.
        if [[ -s "$FILTER_STATUS" ]] && [[ ! -s "$PI_STATUS" ]]; then
            break
        fi
        CUR_SIZE="$(wc -c <"$TMP_OUT" 2>/dev/null || printf '0')"
        NOW_MS=$(_ts_ms)
        if [[ "$CUR_SIZE" != "$LAST_SIZE" ]]; then
            LAST_SIZE="$CUR_SIZE"
            LAST_GROWTH_TS="$NOW_MS"
        fi

        # Trigger (1): terminal agent_end event already present.
        if [[ -z "$RESULT_SEEN_TS" ]] && _has_terminal_agent_end; then
            RESULT_SEEN_TS="$NOW_MS"
        fi
        if [[ -n "$RESULT_SEEN_TS" ]] && _post_result_threshold_compaction; then
            printf 'codegen-call: canceled post-result Pi compaction; terminal result salvaged\n' >&2
            WATCHDOG_KILLED=1
            break
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

        # Trigger (3): dead-stream cap — no output growth for STREAM_IDLE_SECS
        # AND no live tool subprocess. CHILD_PID is the shell supervisor, whose
        # direct child is always Pi; inspect children of the actual Pi process
        # instead so the guard distinguishes Pi itself from a running tool.
        if [[ -z "$(pgrep -P "$PI_PROCESS_PID" 2>/dev/null)" ]] && (((NOW_MS - LAST_GROWTH_TS) / 1000 >= STREAM_IDLE_SECS)); then
            printf 'codegen-call: watchdog killing pi (pid %s) — stream idle %ss, no tool subprocess\n' "$CHILD_PID" "$STREAM_IDLE_SECS" >&2
            WATCHDOG_KILLED=1
            break
        fi
    done

    if [[ -n "$WATCHDOG_KILLED" ]]; then
        _terminate_stream
    fi

    _wait_stream
else
    _start_stream
    _wait_stream
fi

END_TS_MS="$(_ts_ms)"
LATENCY_MS=$((END_TS_MS - START_TS_MS))

# ── Parse JSONL into envelope ─────────────────────────────────────────────────
# Find last agent_end event.
#
# `-R 'fromjson? | ...'` (raw-input + optional-decode) is LOAD-BEARING, not
# style. pi is spawned with `2>&1`, so stderr chatter (cold-session warning,
# model-catalog fetch, deprecation notice) lands in $TMP_OUT interleaved with
# the JSONL. Plain `jq 'select(...)'` HARD-ABORTS on the first non-JSON line
# and emits NOTHING — it does not skip and continue — so one stderr line made
# a fully successful call parse as `no agent_end event found` (empty
# AGENT_END_EVENT → the failed-envelope arm below). `fromjson?` drops
# undecodable lines and keeps going. Mirrors harnesses/claude/call-dispatch.sh,
# which has always parsed with `jq -c -R 'fromjson? | select(.type=="result")'`
# — that tolerance, not a different stderr policy, is why claude never showed
# this bug. Keep every $TMP_OUT scan in this file on `-R 'fromjson?'`.
AGENT_END_EVENT="$(jq -c -R 'fromjson? | select(.type == "agent_end")' "$TMP_OUT" 2>/dev/null | tail -1 || true)"

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
    jq -c -R 'fromjson?' "$TMP_OUT" 2>/dev/null | jq -s '
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

# Extract assistant text from the LAST assistant message in the agent_end event.
# Messages may be an array of {role, content} objects; content is either a
# string or an array of typed blocks.
#
# NEVER pipe this through `head -1`. It used to, and that truncated EVERY
# multi-line pi reply to its first line — silently, on the success path. The
# loop's reviewer contract ("END your response with a line exactly
# `REVIEW_VERDICT: APPROVED`") is the case that exposed it: a reviewer that
# correctly emitted
#
#     | Check | Verdict | Notes |
#     |---|---|---|
#     | Quality | OK | clean |
#
#     REVIEW_VERDICT: APPROVED
#
# reached the loop as the single line `| Check | Verdict | Notes |`, so the
# sentinel was gone and the cycle died with "reviewer output carried no
# parseable REVIEW_VERDICT: sentinel after 2 attempt(s)" — blaming the model
# for a truncation this script performed. Any pi role emitting a trailing
# sentinel, a fenced JSON block, or plain prose past line 1 was corrupted the
# same way. harnesses/claude/call-dispatch.sh takes `.result` whole and never
# truncates; this is the pi twin of that.
#
# `[...] | last` selects the final assistant message (the reply), and the text
# blocks within it are joined with newlines rather than having all but the
# first discarded.
ASSISTANT_TEXT="$(
    printf '%s' "$AGENT_END_EVENT" | jq -r '
        [ .messages // [] | .[] | select(.role == "assistant") ]
        | last
        | if . == null then
              ""
          elif (.content | type) == "array" then
              [ .content[] | select(.type == "text") | .text ] | join("\n")
          elif (.content | type) == "string" then
              .content
          else
              ""
          end
    ' 2>/dev/null || true
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

# Fall back to pi's PER-MESSAGE usage when agent_end carries none.
#
# pi never emits a top-level `agent_end.usage`, nor any `{"type":"usage"}`
# event — the two shapes the reads above and the previous fallback looked for.
# It reports usage per assistant message, in its OWN vocabulary (not claude's):
#
#   {"input":420,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,
#    "totalTokens":425,"cost":{"input":..,"output":..,"total":0.001125}}
#
# Probed live against pi 0.80.10; `.usage` on agent_end is literally absent.
# So EVERY pi call reported input_tokens 0 / cost_usd 0.0, which is why bench
# runs show pi cost as "—" and per_role sums of 0 while claude reports real
# dollars — the harnesses were never actually comparable on cost.
#
# Sum across messages (a multi-turn role bills per turn) and translate pi's
# field names to the envelope's claude-shaped contract. Cost comes from pi's
# own priced `cost.total`, never recomputed here from a local price table that
# would silently rot when the catalog changes.
if [[ "$INPUT_TOKENS" == "0" ]]; then
    PI_USAGE_SUM="$(
        printf '%s' "$AGENT_END_EVENT" | jq -c '
            [ .messages // [] | .[] | .usage | select(. != null) ]
            | {
                input_tokens:                (map(.input // 0)      | add // 0),
                output_tokens:               (map(.output // 0)     | add // 0),
                cache_read_input_tokens:     (map(.cacheRead // 0)  | add // 0),
                cache_creation_input_tokens: (map(.cacheWrite // 0) | add // 0),
                cost_usd:                    (map(.cost.total // 0) | add // 0)
              }
        ' 2>/dev/null || true
    )"

    # NOTE: the intermediate object above deliberately uses the SAME key names
    # as the final envelope's `usage` block. harnesses/shared/
    # call-dispatch-parity_test.sh asserts claude/pi envelope parity by
    # SOURCE-SCANNING each script for `usage: {`-scoped key names, so any
    # differently-named intermediate key here (e.g. a shorthand `cache_read`)
    # leaks into that scan and trips the parity gate with a phantom mismatch.
    if [[ -n "$PI_USAGE_SUM" ]]; then
        INPUT_TOKENS="$(printf '%s' "$PI_USAGE_SUM" | jq -r '.input_tokens')"
        OUTPUT_TOKENS="$(printf '%s' "$PI_USAGE_SUM" | jq -r '.output_tokens')"
        CACHE_READ="$(printf '%s' "$PI_USAGE_SUM" | jq -r '.cache_read_input_tokens')"
        CACHE_CREATION="$(printf '%s' "$PI_USAGE_SUM" | jq -r '.cache_creation_input_tokens')"
        COST_USD="$(printf '%s' "$PI_USAGE_SUM" | jq -r '.cost_usd')"
    fi
fi

# Determine status
STATUS=""
REASON=""
VALUE_JSON="null"

if [[ -z "$ASSISTANT_TEXT" ]]; then
    STATUS="failed"
    # An errored turn still emits agent_end, but with content: [] — so an empty
    # ASSISTANT_TEXT is the SAME observable as a genuine empty reply. The real
    # cause lives in the assistant message's `errorMessage` (e.g. "Codex error:
    # The 'X' model is not supported when using Codex with a ChatGPT account").
    # Surface it: reporting a bare "pi returned empty reply" for a model/auth
    # error sends every future debugger hunting the wrong bug, and the loop's
    # retry classifier needs the real text to spot switch_model/auth failures.
    PI_ERROR_MESSAGE="$(
        printf '%s' "$AGENT_END_EVENT" | jq -r '
            .messages // []
            | reverse
            | map(select(.errorMessage != null and .errorMessage != ""))
            | first
            | if . == null then "" else .errorMessage end
        ' 2>/dev/null || true
    )"
    if [[ -n "$PI_ERROR_MESSAGE" ]]; then
        REASON="$PI_ERROR_MESSAGE"
    else
        REASON="pi returned empty reply"
    fi
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
    VALIDATE_ERR="$(node "$_DISPATCH_SOURCE_DIR/../claude/hooks/lib/schema-validate.js" "$SCHEMA_TMP" "$VALUE_TMP" 2>&1)" || VALIDATE_CODE=$?
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
