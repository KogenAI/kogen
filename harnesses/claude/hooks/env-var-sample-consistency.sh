#!/bin/bash
# env-var-sample-consistency.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
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

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
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

# Extract ADDED-only lines (exclude removed `^-` lines) that call
# System.get_env/fetch_env with a string-literal arg (argless reads like
# `System.get_env()` do not match — nothing to look up in .env.sample).
added_literal_lines=$(printf '%s\n' "$ex_diff" | grep -E '^\+' | grep -E 'System\.(get_env|fetch_env)\(\s*"[^"]+"' || true)
if [ -z "$added_literal_lines" ]; then
    exit 0
fi

# Pull each quoted literal var name and check whether it is already declared
# in the working-tree .env.sample (`^(export )?NAME=`). If .env.sample itself
# is missing, every extracted name is "not declared" (loud, not swallowed —
# no `|| true` around the sample-membership check itself).
new_undocumented=0
while IFS= read -r var_name; do
    [ -z "$var_name" ] && continue
    if ! grep -qE "^(export )?${var_name}=" .env.sample 2>/dev/null; then
        new_undocumented=1
        break
    fi
done <<VARNAMES
$(printf '%s\n' "$added_literal_lines" | grep -oE 'System\.(get_env|fetch_env)\(\s*"[^"]+"' | grep -oE '"[^"]+"' | tr -d '"')
VARNAMES

if [ "$new_undocumented" -eq 0 ]; then
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
