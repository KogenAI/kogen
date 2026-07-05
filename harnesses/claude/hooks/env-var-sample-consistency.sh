#!/bin/bash
# env-var-sample-consistency.sh — SubagentStop hook for developer-phoenix-backend | developer-phoenix-frontend.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: developer-phoenix-backend|developer-phoenix-frontend
# surface: user_global
# signal: AGENT_TYPE
# role: developer-phoenix-backend|developer-phoenix-frontend
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks (re-spawns) the developer subagent if the working-tree diff (vs
# HEAD), scoped to *.ex/*.exs files, adds env-var-reading Elixir code
# (System.get_env / System.fetch_env) but .env.sample and .env.prod.sample
# are NOT also updated to declare the new var. Relocated from a committer
# PreToolUse gate (structural deadlock: committer cannot edit .env.sample)
# to developer SubagentStop, scanning the working-tree diff instead of the
# staged-only diff. Scoped to *.ex/*.exs (not the whole tree) so a
# test-authoring file's string literals (e.g. a fixture that writes
# `System.get_env("X")` into a temp .exs file) never trip this hook.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log env-var-sample-consistency "agent=$AGENT_TYPE stop_active=$STOP_HOOK_ACTIVE"

# Loop guard: this hook may itself trigger a re-spawn (block); avoid re-firing
# on the synthetic re-invocation.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Only gate the developer roles
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend) ;;
*)
    exit 0
    ;;
esac

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cd "$project_dir" 2>/dev/null || exit 0

# Working-tree diff vs HEAD, scoped to *.ex/*.exs files — catches both staged
# and unstaged edits (unlike the old committer gate, which only inspected
# `git diff --cached`). Scoping to Elixir files (not the whole tree) prevents
# false positives from test-authoring files (.sh/.ts) whose string literals
# merely construct fixture text containing the same call-site pattern.
changed_exs=$(git diff HEAD --name-only 2>/dev/null | grep -E '\.exs?$' || true)
if [ -z "$changed_exs" ]; then
    exit 0
fi

wt_diff=$(git diff HEAD -- $changed_exs 2>/dev/null || true)
if [ -z "$wt_diff" ]; then
    exit 0
fi

# Extract ADDED-only lines (exclude removed `^-` lines) that call
# System.get_env/fetch_env with a string-literal arg (argless reads like
# `System.get_env()` do not match — nothing to look up in .env.sample).
added_literal_lines=$(printf '%s\n' "$wt_diff" | grep -E '^\+' | grep -E 'System\.(get_env|fetch_env)\(\s*"[^"]+"' || true)
if [ -z "$added_literal_lines" ]; then
    exit 0
fi

# Pull each quoted literal var name and check whether it is already declared
# in BOTH .env.sample and .env.prod.sample (`^(export )?NAME=`). A var is
# undocumented if undeclared in EITHER sample file. If a sample file itself
# is missing, every extracted name is "not declared" (loud, not swallowed —
# no `|| true` around the membership check itself).
new_undocumented_var=""
while IFS= read -r var_name; do
    [ -z "$var_name" ] && continue
    if ! grep -qE "^(export )?${var_name}=" .env.sample 2>/dev/null ||
        ! grep -qE "^(export )?${var_name}=" .env.prod.sample 2>/dev/null; then
        new_undocumented_var="$var_name"
        break
    fi
done <<VARNAMES
$(printf '%s\n' "$added_literal_lines" | grep -oE 'System\.(get_env|fetch_env)\(\s*"[^"]+"' | grep -oE '"[^"]+"' | tr -d '"')
VARNAMES

if [ -z "$new_undocumented_var" ]; then
    exit 0
fi

block "BLOCKED by env-var-sample-consistency: new env var '$new_undocumented_var' is read (System.get_env/fetch_env) in the working-tree diff but is not declared in .env.sample and/or .env.prod.sample. Add it to BOTH sample files, then stop again."
exit 0
