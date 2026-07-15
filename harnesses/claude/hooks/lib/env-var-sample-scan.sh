#!/usr/bin/env bash
# env-var-sample-scan.sh — standalone working-tree env-var sample-consistency scan
# (extracted for reuse by the in-loop `run_env_var_step`).
#
# Scans the WORKING-TREE diff (vs HEAD), scoped to *.ex/*.exs files, for
# newly-added env-var reads (System.get_env / System.fetch_env with a
# string-literal arg) whose var name is NOT declared in BOTH .env.sample
# and .env.prod.sample. Extracted from env-var-sample-consistency.sh so the
# same scan can run as an in-loop Elixir step
# (OrchestrationLoop.run_env_var_step) — the loop invokes roles as
# main-agent `codegen-call` calls with no SubagentStop event, so the
# original hook alone never fires in the build path.
#
# Usage: env-var-sample-scan.sh <repo_root>
#
# Exit 0: clean (no undocumented vars). Prints nothing.
# Exit 1: violations found. Prints one undocumented VAR name per line to stdout.
#
# No hook I/O — no parse_input, no block. Pure scan.

set -uo pipefail

repo_root="${1:-}"
if [ -z "$repo_root" ]; then
    exit 0
fi

cd "$repo_root" 2>/dev/null || exit 0

# Working-tree diff vs HEAD, scoped to *.ex/*.exs files — catches both staged
# and unstaged edits.
changed_exs=$(git diff HEAD --name-only 2>/dev/null | grep -E '\.exs?$' || true)
if [ -z "$changed_exs" ]; then
    exit 0
fi

wt_diff=$(git diff HEAD -- $changed_exs 2>/dev/null || true)
if [ -z "$wt_diff" ]; then
    exit 0
fi

# Extract ADDED-only lines (exclude removed `^-` lines) that call
# System.get_env/fetch_env with a SINGLE string-literal arg — i.e. the
# literal is immediately followed by a closing paren (whitespace-tolerant).
# This is the REQUIRED-read form (no default) and can crash the app on a
# missing var. A defaulted 2-arg read (`System.get_env("X", default)`) has
# a `,` after the literal, not `)`, so it does NOT match — it can never
# crash, so it is exempt from the sample-consistency requirement. Argless
# reads like `System.get_env()` also do not match — nothing to look up.
added_literal_lines=$(printf '%s\n' "$wt_diff" | grep -E '^\+' | grep -E 'System\.(get_env|fetch_env)\(\s*"[^"]+"\s*\)' || true)
if [ -z "$added_literal_lines" ]; then
    exit 0
fi

# Pull each quoted literal var name and check whether it is already declared
# in BOTH .env.sample and .env.prod.sample (`^(export )?NAME=`). A var is
# undocumented if undeclared in EITHER sample file. If a sample file itself
# is missing, every extracted name is "not declared" (loud, not swallowed —
# no `|| true` around the membership check itself).
undocumented_vars=""
while IFS= read -r var_name; do
    [ -z "$var_name" ] && continue
    if ! grep -qE "^(export )?${var_name}=" .env.sample 2>/dev/null ||
        ! grep -qE "^(export )?${var_name}=" .env.prod.sample 2>/dev/null; then
        undocumented_vars="${undocumented_vars}${var_name}
"
    fi
done <<VARNAMES
$(printf '%s\n' "$added_literal_lines" | grep -oE 'System\.(get_env|fetch_env)\(\s*"[^"]+"\s*\)' | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
VARNAMES

if [ -z "$undocumented_vars" ]; then
    exit 0
fi

printf '%s' "$undocumented_vars"
exit 1
