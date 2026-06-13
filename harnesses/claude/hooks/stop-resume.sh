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
haystack="$LAST_ASSISTANT_MESSAGE"

if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    transcript_errors=$(tail -n 10 "$TRANSCRIPT_PATH" 2>/dev/null |
        jq -r '
        (select(.isApiErrorMessage == true)
          | (.message.content // [] | map(select(.type == "text") | .text) | join(" "))),
        (select(.type == "user")
          | (.message.content // []
              | map(select(.type == "tool_result")
                  | (.content // []
                      | if type == "array"
                        then map(select(.type == "text") | .text) | join(" ")
                        else tostring
                        end))
              | join(" ")))
      ' 2>/dev/null |
        tr '\n' ' ')
    if [ -n "$transcript_errors" ]; then
        haystack="$haystack $transcript_errors"
    fi
fi

# --- Classify ---------------------------------------------------------------
retryable_regex='Stream idle timeout|Unable to connect|FailedToOpenSocket|ConnectionRefused|API Error: 529|API Error: 500|API Error: 502|API Error: 503|API Error: 504|overloaded_error|Internal server error|upstream connect error|connection reset|socket hang up|ETIMEDOUT|context deadline exceeded|File has been modified since read|has been unexpectedly modified|socket connection was closed'
rate_limit_regex='API Error: 429|rate_limit|rate limit'
hard_fail_regex='API Error: 400|API Error: 401|API Error: 403|API Error: 404|Prompt is too long|invalid_api_key|authentication_error|permission_error'

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

# --- Emit block decision ----------------------------------------------------
reason="⏳ Transient network error (socket closed or API unavailable). Auto-resuming, attempt ${count}/8. Re-read the session log in codegen/logging/ and continue where you left off. Consider breaking the next action into smaller steps to avoid another timeout."

block "$reason"
exit 0
