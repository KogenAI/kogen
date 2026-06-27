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
# Blocks Stop when:
#   A developer-* Agent call appears in the transcript AND no Write to a
#   codegen/logging/*.md path appears in the transcript.
#   → Step log was never created; orchestrator violated the "create log FIRST"
#     rule. Block and instruct it to create the log, then re-delegate.
#
# Skip when:
#   - STOP_HOOK_ACTIVE=true (recursion guard)
#   - TRANSCRIPT_PATH unset or unreadable
#   - No developer-* Agent call in transcript
#   - developer-* Agent call present AND a Write to codegen/logging/*.md present
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

# Investigative-mode skip: this build-runtime gate enforces ONLY in build mode
# (empty role). Skip (exit 0) for any non-empty investigative role (shape/debug/
# ops/experiment) — mirrors signal: CLAUDE_ROLE_FAMILY. Inverse of pitch-format-validator.
source "$(dirname "$0")/_role.sh"
role=$(resolve_role)
if [ -n "$role" ]; then
    debug_log step-log-missing-guard "skip: investigative role=$role"
    exit 0
fi

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

# ── Check transcript for developer-* Agent call ──────────────────────────────

has_developer_agent=$(jq -r '
    .message.content[]?
    | select(.type == "tool_use" and .name == "Agent")
    | select(.input.subagent_type // "" | test("^developer-"))
    | "yes"
' "$TRANSCRIPT_PATH" 2>/dev/null | grep -c "yes" || true)

if [ "${has_developer_agent:-0}" -eq 0 ]; then
    debug_log step-log-missing-guard "skip: no developer-* Agent call in transcript"
    exit 0
fi

debug_log step-log-missing-guard "developer-* Agent call found"

# ── Check transcript for Write to codegen/logging/*.md ───────────────────────

log_file=$(session_log_from_transcript)

if [ -n "$log_file" ]; then
    debug_log step-log-missing-guard "skip: log write found ($log_file)"
    exit 0
fi

# ── Block: developer-* delegated but no step log created ─────────────────────

template='codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_session.md'

bash_redirect_create=$(jq -r '
    .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | select(.input.command | test("(>+|tee[^|]*)[[:space:]]*[^[:space:]]*codegen/logging/[^[:space:]]+\\.md"))
    | "yes"
' "$TRANSCRIPT_PATH" 2>/dev/null | grep -c "yes" || true)

if [ "${bash_redirect_create:-0}" -gt 0 ]; then
    reason_br="step-log-missing-guard: step log was created via Bash redirect (e.g., \`cat > ... << EOF\`, \`echo > ...\`, \`tee\`). The gate hook (phoenix-dev-gate.sh) and this guard discover logs via Write|Edit|MultiEdit tool_use entries only. Recreate the log using the Write tool. Path template: ${template} Do not investigate why this fired — do the above and retry."
    debug_log step-log-missing-guard "BLOCK: bash-redirect step-log creation detected"
    block "$reason_br"
    exit 0
fi

reason="step-log-missing-guard: a developer-* subagent was delegated but no step log Write was found in the session transcript. Per codegen/rules/_core/session-log.md § Ownership, the orchestrator MUST create the step log BEFORE the first Agent call — for ALL prompt types including free-form and claude-build invocations. Action required: (1) Create the step log now using the single-session form: ${template} (2) Populate the ## Plan section from the planner's output. (3) Re-delegate to the developer-* subagent. Do not investigate why this fired — do the above and retry."

debug_log step-log-missing-guard "BLOCK: no log write in transcript"

block "$reason"
exit 0
