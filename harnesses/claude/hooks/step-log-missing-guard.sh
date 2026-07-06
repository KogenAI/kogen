#!/usr/bin/env bash
# step-log-missing-guard.sh — Stop hook that blocks the orchestrator from
# stopping when a developer-* subagent was called but no step log Write
# appears in the session transcript.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks Stop when (POSITION-CORRELATED, not existence-scanned):
#   The LAST developer-* Agent tool_use in transcript order has NO step-log
#   creation after it — i.e. last_dev_index exists AND (no log-creation evidence
#   at all OR last_log_index < last_dev_index). Log-creation evidence =
#   Write/Edit/MultiEdit to codegen/logging/*.jsonl OR a Bash codegen-log
#   (init|section|append) invocation.
#   → The current cycle's delegation was never logged. Block with a DIAGNOSTIC
#     message naming the unlogged delegation.
#
# Skip when:
#   - STOP_HOOK_ACTIVE=true (recursion guard)
#   - TRANSCRIPT_PATH unset or unreadable
#   - No developer-* Agent call in transcript (last_dev_index empty)
#   - A step-log creation appears AT OR AFTER the last developer-* delegation
#     (last_log_index >= last_dev_index) — resolved-and-logged cycle no longer
#     arms the guard, killing stale replay
#   - Last assistant message indicates async wait
#   - Last assistant message matches intent regex (asking user a question)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

session_id="${SESSION_ID:-unknown}"

debug_log step-log-missing-guard "session=$session_id"

# Loop guard
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log step-log-missing-guard "skip: stop_hook_active"
    exit 0
fi

# Investigative-mode skip: this build-runtime gate enforces ONLY in build mode.
# Skip (exit 0) for any investigative role (shape/debug/ops/experiment/refactor)
# via is_build_mode() — mirrors signal: CLAUDE_ROLE_FAMILY.
source "$(dirname "$0")/_role.sh"
is_build_mode || {
    debug_log step-log-missing-guard "skip: investigative role=$(resolve_role)"
    exit 0
}

# Transcript guard — cannot inspect without transcript
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log step-log-missing-guard "skip: no transcript"
    exit 0
fi

# Intent guard: orchestrator is asking the user something — let it stop.
# Only honor in INTERACTIVE sessions; headless builds fall through to block.
trimmed=$(printf '%s' "$LAST_ASSISTANT_MESSAGE" | sed -E 's/[[:space:]]+$//')
last_char="${trimmed: -1}"
intent_regex='[Ss]hould I|[Nn]eed clarification|[Bb]locked|[Ss]tuck|[Ww]aiting for|[Pp]lease confirm|[Ww]ant me to|[Cc]onfirm before'
if [ -z "${CODEGEN_BUILD_NON_INTERACTIVE:-}" ]; then
    if [ "$last_char" = "?" ] || printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE "$intent_regex"; then
        debug_log step-log-missing-guard "skip: intent question detected"
        exit 0
    fi
else
    debug_log step-log-missing-guard "headless: intent escape suppressed (CODEGEN_BUILD_NON_INTERACTIVE set) — falling through to block logic"
fi

# Async-wait guard: orchestrator is yielding for a background event.
if printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE 'ScheduleWakeup|scheduled.*wakeup|checking back in|seed rebuild|still running|in flight'; then
    debug_log step-log-missing-guard "skip: async-wait signal in last message"
    exit 0
fi

# ── Position-correlated trigger ──────────────────────────────────────────────
# Compute, in transcript order, the index of the LAST developer-* Agent tool_use
# and the index of the LAST step-log-creation evidence. Block only when a
# developer-* delegation has NO log-creation after it. This replaces the two
# unbounded existence scans that caused stale replay: a resolved-and-logged
# delegation from an earlier cycle no longer arms the guard once its log index
# moves past its delegation index.

last_dev_index=$(jq -r '
    input_line_number as $ln
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Agent")
    | select(.input.subagent_type // "" | test("^developer-"))
    | $ln
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)

# No developer-* delegation anywhere → nothing to enforce.
if [ -z "$last_dev_index" ]; then
    debug_log step-log-missing-guard "skip: no developer-* Agent call in transcript"
    exit 0
fi

# Log-creation evidence = Write/Edit/MultiEdit to codegen/logging/*.jsonl OR a
# Bash codegen-log (init|section|append) invocation (same two forms recognized
# by session_log_from_transcript in hooks-lib.sh; inlined here so the trigger
# stays position-correlated instead of an existence check).
last_log_index=$(jq -r '
    input_line_number as $ln
    | .message.content[]?
    | select(.type == "tool_use")
    | select(
        ((.name == "Write" or .name == "Edit" or .name == "MultiEdit")
            and (.input.file_path // "" | test("codegen/logging/.*\\.jsonl$")))
        or (.name == "Bash"
            and (.input.command // "" | test("codegen-log[[:space:]]+(init|section|append)")))
    )
    | $ln
' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)

# Allow when a step log was created AT OR AFTER the last developer-* delegation.
# Tie (same assistant message: delegate + create log in one turn) allows.
if [ -n "$last_log_index" ] && [ "$last_log_index" -ge "$last_dev_index" ]; then
    debug_log step-log-missing-guard "skip: log created at/after last dev delegation (log=$last_log_index dev=$last_dev_index)"
    exit 0
fi

# ── Belt-and-suspenders: .active sentinel mtime ──────────────────────────────
# The transcript-position scan above can lag a live codegen-log write (Bash
# tool_use entries land in the transcript asynchronously). codegen/logging/.active
# is a synchronous disk write (codegen-log init/relocate) — if it exists, points
# at a log that still exists, AND its mtime is at or after the transcript file's
# own mtime (i.e. the sentinel was touched no earlier than the most recent
# transcript activity we can observe), treat that as equivalent satisfying
# evidence. EITHER signal (transcript position OR sentinel mtime) is sufficient;
# neither replaces the other — this only closes the async-lag gap, it never
# narrows the transcript-based check.
active_sentinel="${CWD:-$PWD}/codegen/logging/.active"
if [ -f "$active_sentinel" ]; then
    sentinel_target=$(cat "$active_sentinel" 2>/dev/null || true)
    if [ -n "$sentinel_target" ] && [ -e "$sentinel_target" ]; then
        sentinel_mtime=$(stat -f '%m' "$active_sentinel" 2>/dev/null || stat -c '%Y' "$active_sentinel" 2>/dev/null || echo 0)
        transcript_mtime=$(stat -f '%m' "$TRANSCRIPT_PATH" 2>/dev/null || stat -c '%Y' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
        if [ "$sentinel_mtime" -ge "$transcript_mtime" ]; then
            debug_log step-log-missing-guard "skip: .active sentinel mtime ($sentinel_mtime) >= transcript mtime ($transcript_mtime) — treated as satisfying evidence"
            exit 0
        fi
    fi
fi

debug_log step-log-missing-guard "developer-* delegation at line $last_dev_index has no log-creation after it (last_log_index=${last_log_index:-none})"

# ── Block: developer-* delegated but no step log created ─────────────────────

template='codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_cycle.jsonl'

bash_redirect_create=$(jq -r '
    .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | select(.input.command | test("(>+|tee[^|]*)[[:space:]]*[^[:space:]]*codegen/logging/[^[:space:]]+\\.jsonl"))
    | "yes"
' "$TRANSCRIPT_PATH" 2>/dev/null | grep -c "yes" || true)

# build_and_fire_breadcrumb <branch> — best-effort diagnostic append before a
# block(). Captures position indices + sentinel/mtime state. NEVER alters the
# block verdict — guard_breadcrumb is fully fail-open internally.
build_and_fire_breadcrumb() {
    local branch="$1"
    local bc_ts bc_transcript_mtime bc_sentinel_target bc_sentinel_mtime
    bc_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bc_transcript_mtime=$(stat -f '%m' "$TRANSCRIPT_PATH" 2>/dev/null || stat -c '%Y' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
    bc_sentinel_target="${sentinel_target:-}"
    bc_sentinel_mtime="${sentinel_mtime:-}"
    local bc
    bc=$(jq -n \
        --arg ts "$bc_ts" \
        --arg guard "step-log-missing-guard" \
        --arg session_id "$session_id" \
        --arg transcript_path "${TRANSCRIPT_PATH:-}" \
        --arg transcript_mtime "$bc_transcript_mtime" \
        --arg last_dev_index "${last_dev_index:-}" \
        --arg last_log_index "${last_log_index:-none}" \
        --arg active_sentinel_target "$bc_sentinel_target" \
        --arg codegen_log_path_env "${CODEGEN_LOG_PATH:-}" \
        --arg sentinel_mtime "$bc_sentinel_mtime" \
        --arg block_branch "$branch" \
        '{ts: $ts, guard: $guard, session_id: $session_id, transcript_path: $transcript_path,
          transcript_mtime: ($transcript_mtime | tonumber), last_dev_index: ($last_dev_index | tonumber? // null),
          last_log_index: $last_log_index, active_sentinel_target: $active_sentinel_target,
          codegen_log_path_env: $codegen_log_path_env, sentinel_mtime: $sentinel_mtime,
          block_branch: $block_branch}' 2>/dev/null)
    guard_breadcrumb "$session_id" "$bc"
}

if [ "${bash_redirect_create:-0}" -gt 0 ]; then
    reason_br="step-log-missing-guard: step log was created via Bash redirect (e.g., \`cat > ... << EOF\`, \`echo > ...\`, \`tee\`). The gate hook (phoenix-dev-gate.sh) and this guard discover logs via Write|Edit|MultiEdit tool_use entries only. Recreate the log using the Write tool. Path template: ${template} A developer-* delegation (transcript line ${last_dev_index}) has no Write/Edit/MultiEdit or codegen-log step-log creation after it. If a delegation is genuinely pending this turn, recreate the log via the Write tool or codegen-log and retry. If NO developer-* delegation is pending this turn, this is a STALE trigger — report it as a stale step-log-missing-guard replay rather than fabricate a step log."
    debug_log step-log-missing-guard "BLOCK: bash-redirect step-log creation detected"
    build_and_fire_breadcrumb "bash-redirect"
    block "$reason_br"
    exit 0
fi

reason="step-log-missing-guard: a developer-* subagent was delegated but no step log Write was found in the session transcript. Per codegen/rules/_core/session-log.md § Ownership, the orchestrator MUST create the step log BEFORE the first Agent call — for ALL prompt types including free-form and claude-build invocations. Action required: (1) Create the step log now using the single-session form: ${template} (2) Record the planner's role event via 'codegen-log section planner-phoenix --slug <slug>' (or the matching planner-* role). (3) Re-delegate to the developer-* subagent. This block keyed on a developer-* delegation at transcript line ${last_dev_index} with no step-log creation after it. If NO developer-* delegation is actually pending this turn, this is a STALE trigger — report it as a stale step-log-missing-guard replay rather than fabricate a step log; do NOT blindly re-delegate work that was not requested this turn."

debug_log step-log-missing-guard "BLOCK: no log write in transcript"

build_and_fire_breadcrumb "no-log"
block "$reason"
exit 0
