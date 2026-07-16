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

# Ambient OS/shell-owned env var names — never supplied by a deployer via
# .env; owned by the OS/shell environment itself. A required read of one of
# these can never be "undeclared app config" and must never be flagged.
# LC_* is matched as a prefix family (POSIX locale vars: LC_ALL, LC_COLLATE,
# LC_CTYPE, ...); the rest are exact, case-sensitive whole-name matches.
AMBIENT_OS_VARS="HOME USER LOGNAME PATH PWD SHELL TERM TMPDIR LANG HOSTNAME"

is_ambient_var() {
    local name="$1" candidate
    case "$name" in
    LC_*) return 0 ;;
    esac
    for candidate in $AMBIENT_OS_VARS; do
        [ "$name" = "$candidate" ] && return 0
    done
    return 1
}

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
# System.get_env/fetch_env/fetch_env! with a string-literal var name arg —
# ANY read shape (bare, defaulted 2-arg, `||`-fallback, `case`, `==`, spaced).
# The axis here is DOCUMENTATION, not crash-ability: a deployer needs to know
# the var exists regardless of whether the read can crash on absence (in
# fact zero `fetch_env!` call sites exist repo-wide today, so a crash-axis
# gate would be a near-inert no-op). The only exemption is the ambient-OS
# allowlist above — an ownership axis (HOME/PATH/LC_* are never
# deployer-supplied app config), orthogonal to read shape. Argless reads
# like `System.get_env()` still do not match — nothing to look up.
added_literal_lines=$(printf '%s\n' "$wt_diff" | grep -E '^\+' | grep -E 'System\.(get_env|fetch_env!?)\(\s*"[A-Z_][A-Z0-9_]*"\s*[,)]' || true)
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
    is_ambient_var "$var_name" && continue
    if ! grep -qE "^(export )?${var_name}=" .env.sample 2>/dev/null ||
        ! grep -qE "^(export )?${var_name}=" .env.prod.sample 2>/dev/null; then
        undocumented_vars="${undocumented_vars}${var_name}
"
    fi
done <<VARNAMES
$(printf '%s\n' "$added_literal_lines" | grep -oE 'System\.(get_env|fetch_env!?)\(\s*"[A-Z_][A-Z0-9_]*"\s*[,)]' | grep -oE '"[A-Z_][A-Z0-9_]*"' | tr -d '"' | sort -u)
VARNAMES

if [ -z "$undocumented_vars" ]; then
    exit 0
fi

printf '%s' "$undocumented_vars"
exit 1
