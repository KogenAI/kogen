#!/bin/bash
# prompt-budget-writer-only.sh — PreToolUse Bash|Edit|Write|MultiEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# rationale: templates/generator/prompt-budgets.txt has exactly one legitimate writer — an operator running `prompt_size_budget.py --write` in a terminal. Raw Edit/Write/MultiEdit on the file, the --write flag itself, and Bash write-vocab (redirect/tee/sed -i/mv/cp) into the path are all denied for every agent role, including the orchestrator. A capped file that overflows must shrink or evict — the cap is not the writer's to move.
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Bypasses debug/shape/ops. Fails open on all tools other than Bash/Edit/Write/MultiEdit.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log prompt-budget-writer-only "tool=$TOOL_NAME file=${FILE_PATH:-} cmd=${COMMAND:-}"

BUDGET_PATH_RE='templates/generator/prompt-budgets\.txt$'

# Investigative-mode bypass (sibling-guard convention).
_role=$(resolve_role)
case "$_role" in debug | shape | ops) exit 0 ;; esac

deny_msg="BLOCKED by prompt-budget-writer-only: this file is operator-owned — raising a prompt budget is denied for every agent role. This file is full: shrink your addition, or evict the lowest-value content and name what you evicted in your diff. The cap is not the writer's to move."

case "$TOOL_NAME" in
Edit | Write | MultiEdit)
    if printf '%s' "$FILE_PATH" | grep -qE "$BUDGET_PATH_RE"; then
        deny "$deny_msg"
        exit 0
    fi
    exit 0
    ;;
Bash)
    # A codegen-log write narrates gated phrases in its heredoc/piped body
    # (e.g. a retrospective mentioning "prompt_size_budget.py --write" as
    # something that was FIXED); it is never the gated action itself. Bypass
    # before any phrase match, mirroring dev-no-ci.sh / developer-no-self-gate.sh.
    if is_codegen_log_write; then
        exit 0
    fi
    # Deny the --write flag itself, wherever invoked.
    if printf '%s' "$COMMAND" | grep -qE 'prompt_size_budget\.py.*--write'; then
        deny "$deny_msg"
        exit 0
    fi
    # Deny Bash write-vocab (redirect, tee, in-place-stream-edit, move/copy-into)
    # targeting the budget file directly.
    if printf '%s' "$COMMAND" | grep -qE 'templates/generator/prompt-budgets\.txt'; then
        if printf '%s' "$COMMAND" | grep -qE '(>{1,2}[[:space:]]*[^[:space:]]*templates/generator/prompt-budgets\.txt|\|[[:space:]]*tee\b.*templates/generator/prompt-budgets\.txt|\bsed\b[^|]*-i[^|]*templates/generator/prompt-budgets\.txt|\b(mv|cp)\b[^|]*templates/generator/prompt-budgets\.txt)'; then
            deny "$deny_msg"
            exit 0
        fi
    fi
    exit 0
    ;;
*)
    exit 0
    ;;
esac
