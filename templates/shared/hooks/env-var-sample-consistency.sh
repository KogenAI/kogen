#!/bin/bash
# env-var-sample-consistency.sh — PreToolUse Bash hook scoped to committer.
#
# Blocks a git commit if staged files include env-var-reading Elixir code
# (System.get_env / System.fetch_env) but .env.sample and .env.prod.sample
# are NOT also staged.
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_EVSC_DEBUG:-}" ]; then
    printf '%s tool=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_type" \
        >>/tmp/env-var-sample-consistency-debug.log 2>/dev/null || true
fi

# Only gate committer
if [ "$agent_type" != "committer" ]; then
    exit 0
fi

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only inspect git commit commands
if ! printf '%s' "$command" | grep -qE '\bgit[[:space:]]+commit\b'; then
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
printf 'BLOCKED by env-var-sample-consistency: commit touches env-var-reading code (%s) but does not stage .env.sample / .env.prod.sample. Add both samples and re-stage.\n' \
    "$offending" >&2
exit 2
