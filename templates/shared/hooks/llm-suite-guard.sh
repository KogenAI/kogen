#!/bin/bash
# llm-suite-guard.sh — PreToolUse hook: deny bare `make llm` / `make llm-phoenix` for developer-*.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*
#
# Blocks: bare `make llm` and `make llm-phoenix` (no further subcommand suffix).
#
# Allow-list (pass through without denial):
#   make llm-single, make llm-retry, make llm-summary, make llm-trace,
#   make llm-kill, make llm-budget, make llm-all,
#   make llm-phoenix-{seed,validate,retry,trace,kill,summary,cache}
#
# Note: dev-no-ci.sh fires alphabetically first and already denies `make llm`
# and `make llm-phoenix`. This hook is belt-to-suspenders with a refusal message
# that explicitly names `make llm-single` as the correct alternative.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log llm-suite-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only enforce for developer-* subagents.
case "$AGENT_TYPE" in
developer-*) ;;
*) exit 0 ;;
esac

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Deny bare `make llm` (no suffix) or `make llm-phoenix` (no suffix).
# Anchored: must be start-of-command (optional whitespace), then `make llm` or
# `make llm-phoenix`, followed by end-of-string or whitespace (not a hyphen).
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(llm|llm-phoenix)([[:space:]]|$)'; then
    deny "Devs MUST NOT run the full LLM suite. Use \`make llm-single FILE=<path>\` to iterate on one file. The gate runs \`make llm\`/\`make llm-phoenix\` after you exit."
    exit 0
fi

exit 0
