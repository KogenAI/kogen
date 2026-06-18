#!/usr/bin/env bash
# Stop hook: auto-resume Claude Code when a session ends due to a transient
# network/API error (stream idle timeout, 500/529, connection refused, etc.)
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: none
# role: *
# harnesses: all
# timeout: 360
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

session_id="${SESSION_ID:-unknown}"

counter_file="/tmp/claude-resume-${session_id}.count"

# --- Loop guard -------------------------------------------------------------
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# --- Gather candidate error text -------------------------------------------
# Classify ONLY from transcript records the harness itself stamped as errors:
#   isApiErrorMessage == true            (synthetic terminal-error message)
#   type == "system" and subtype == "api_error"  (SDK transient-fault events)
# Free prose (LAST_ASSISTANT_MESSAGE) and tool_result text are NOT trustworthy
# error signals — a session that merely quotes/reads an error name must NOT
# trip the classifier. See pitch stop-resume-classify-from-error-records-only.
haystack=""

if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    haystack=$(tail -n 10 "$TRANSCRIPT_PATH" 2>/dev/null |
        jq -r '
        select(.isApiErrorMessage == true
               or (.type == "system" and .subtype == "api_error"))
        | (.message.content // [] | map(select(.type == "text") | .text) | join(" ")),
          (.error.message // empty),
          (.error.connection.message // empty)
      ' 2>/dev/null |
        tr '\n' ' ')
fi

# --- Classify ---------------------------------------------------------------
# Classification regexes live in the harness-agnostic shared fragment so the
# (claude + pi) dispatch retry loops can source the same taxonomy. Single
# source of truth — do not re-inline here.
source "$(dirname "$0")/../../shared/retryable-errors.sh"

is_retryable=0

if printf '%s' "$haystack" | grep -qE "$hard_fail_regex"; then
    is_retryable=0
elif printf '%s' "$haystack" | grep -qE "$rate_limit_regex"; then
    is_retryable=0
elif printf '%s' "$haystack" | grep -qE "$retryable_regex"; then
    is_retryable=1
fi

# --- Non-retryable: normal stop, hard failure, or rate-limit ---------------
if [ "$is_retryable" = "0" ]; then
    rm -f "$counter_file"
    exit 0
fi

# --- Retry cap --------------------------------------------------------------
count=0
if [ -r "$counter_file" ]; then
    count=$(cat "$counter_file" 2>/dev/null || echo 0)
fi
case "$count" in
'' | *[!0-9]*) count=0 ;;
esac

if [ "$count" -ge 8 ]; then
    rm -f "$counter_file"
    exit 0
fi

count=$((count + 1))
printf '%s' "$count" >"$counter_file"

# --- Inter-attempt backoff (space out retries; do not stampede an overloaded API) -------
# Schedule keyed on attempt count (1..8). Immediate first retry preserves prior behavior;
# subsequent waits grow then cap at 5 min. Hook `timeout` (360s) in the registration must
# be >= the max delay (set in shared/enforcement/registry.yaml id: stop-resume).
case "$count" in
1) delay=0 ;;   # first retry: immediate
2) delay=60 ;;  # 1 min
3) delay=300 ;; # 5 min
*) delay=300 ;; # cap subsequent waits at 5 min
esac
if [ "$delay" -gt 0 ]; then
    sleep "$delay"
fi

# --- Emit block decision ----------------------------------------------------
reason="⏳ Transient network error (socket closed or API unavailable). Auto-resuming, attempt ${count}/8. Re-read the session log in codegen/logging/ and continue where you left off. Consider breaking the next action into smaller steps to avoid another timeout."

block "$reason"
exit 0
