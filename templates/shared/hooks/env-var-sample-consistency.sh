#!/bin/bash
# env-var-sample-consistency.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
#
# Blocks a git commit if staged files include env-var-reading Elixir code
# (System.get_env / System.fetch_env) but .env.sample and .env.prod.sample
# are NOT also staged.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log env-var-sample-consistency "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate committer
if [ "$AGENT_TYPE" != "committer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only inspect git commit commands
if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi

# Get staged files
staged_files=$(git diff --cached --name-only 2>/dev/null || true)
if [ -z "$staged_files" ]; then
    exit 0
fi

# Check if any staged .ex/.exs file has System.get_env or System.fetch_env changes
staged_exs=$(printf '%s\n' "$staged_files" | grep -E '\.exs?$' || true)
if [ -z "$staged_exs" ]; then
    exit 0
fi

# Get the diff for staged Elixir files
ex_diff=$(git diff --cached -- $staged_exs 2>/dev/null || true)
if [ -z "$ex_diff" ]; then
    exit 0
fi

# Check if diff contains System.get_env or System.fetch_env additions/removals
if ! printf '%s' "$ex_diff" | grep -qE '^[+-].*System\.(get_env|fetch_env)'; then
    exit 0
fi

# Env-var code is in the staged diff. Check that both sample files are staged.
has_env_sample=$(printf '%s\n' "$staged_files" | grep -c '\.env\.sample$' || true)
has_prod_sample=$(printf '%s\n' "$staged_files" | grep -c '\.env\.prod\.sample$' || true)

if [ "$has_env_sample" -ge 1 ] && [ "$has_prod_sample" -ge 1 ]; then
    exit 0
fi

# Find the offending files for the error message
offending=$(printf '%s\n' "$staged_exs" | tr '\n' ' ')
deny "BLOCKED by env-var-sample-consistency: commit touches env-var-reading code ($offending) but does not stage .env.sample / .env.prod.sample. Add both samples and re-stage."
exit 0
