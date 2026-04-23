#!/usr/bin/env bash
# Stop hook: auto-resume Claude Code when a session ends due to a transient
# network/API error (stream idle timeout, 500/529, connection refused, etc.)
#
# Protocol:
#   - Claude Code pipes a JSON payload on stdin (session_id, transcript_path,
#     stop_hook_active, last_assistant_message, ...)
#   - To resume: print `{"decision":"block","reason":"..."}` to stdout, exit 0.
#     Claude injects a synthetic user turn "Stop hook feedback:\n<reason>".
#   - To let the session end normally: exit 0 with no JSON output.
#
# Detection strategy: check `last_assistant_message` for known error strings
# AND grep the tail of `transcript_path` for isApiErrorMessage entries (catches
# top-level errors) and tool_result contents (catches subagent errors that
# terminated the parent session).
#
# Loop guard: if stop_hook_active == true, this hook already fired once for
# this stop — exit immediately so we can never recurse.
#
# Retry cap: at most 3 retries per session, tracked via
# /tmp/claude-resume-<session_id>.count. After that we give up and let the
# session end.

set -u

# --- Read stdin -------------------------------------------------------------
input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
last_assistant_message=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""')

counter_file="/tmp/claude-resume-${session_id}.count"

# --- Loop guard -------------------------------------------------------------
if [ "$stop_hook_active" = "true" ]; then
    exit 0
fi

# --- Gather candidate error text -------------------------------------------
# Source 1: last_assistant_message (populated when top-level session errors).
# Source 2: tail of transcript JSONL — two patterns:
#   a) isApiErrorMessage == true entries (top-level session error)
#   b) tool_result contents in user entries (subagent error returned to parent)
haystack="$last_assistant_message"

if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
    transcript_errors=$(tail -n 10 "$transcript_path" 2>/dev/null |
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
retryable_regex='Stream idle timeout|Unable to connect|FailedToOpenSocket|ConnectionRefused|API Error: 529|API Error: 500|overloaded_error|Internal server error'
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

if [ "$count" -ge 3 ]; then
    rm -f "$counter_file"
    exit 0
fi

count=$((count + 1))
printf '%s' "$count" >"$counter_file"

# --- Emit block decision ----------------------------------------------------
reason="Network/API error detected (stream idle timeout or transient API failure). Auto-resuming (attempt ${count}/3). Re-read the session log in codegen/logging/ and continue where you left off. Consider breaking the next action into smaller steps to avoid another timeout."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
exit 0
