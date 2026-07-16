#!/bin/bash
# session-log-writer-only.sh — PreToolUse Bash|Edit|Write|MultiEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# rationale: codegen-log is the SOLE writer of cycle logs — raw Edit/Write/MultiEdit on codegen/logging/*.jsonl, and raw Bash writes (redirect/tee/in-place-stream-edit/move-into) into that path, are denied. All log mutation must route through codegen-log init / section <role> (stdin or --body "<text>") / append <role>.
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Bypasses debug/shape/ops. Fails open on all tools other than Bash/Edit/Write/MultiEdit.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log session-log-writer-only "tool=$TOOL_NAME file=${FILE_PATH:-} cmd=${COMMAND:-}"

# Investigative-mode bypass (sibling-guard convention).
_role=$(resolve_role)
case "$_role" in debug | shape | ops) exit 0 ;; esac

case "$TOOL_NAME" in
Edit | Write | MultiEdit)
    if printf '%s' "$FILE_PATH" | grep -qE 'codegen/logging/.*\.jsonl$'; then
        deny "BLOCKED by session-log-writer-only: raw $TOOL_NAME on cycle logs is denied — write via codegen-log (init / section --body @- / section --role <role> / append --role <role>)."
        exit 0
    fi
    exit 0
    ;;
Bash)
    # Allow any command that invokes codegen-log — the sole legitimate writer.
    if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]/])codegen-log\b'; then
        exit 0
    fi
    # Deny any command that writes into codegen/logging/* without codegen-log:
    # redirects (> >>), tee, in-place stream-edit (sed -i), or move/copy INTO
    # the path (mv/cp ... codegen/logging/...).
    if printf '%s' "$COMMAND" | grep -qE 'codegen/logging/[^[:space:]]*\.jsonl'; then
        if printf '%s' "$COMMAND" | grep -qE '(>{1,2}[[:space:]]*[^[:space:]]*codegen/logging/|\|[[:space:]]*tee\b.*codegen/logging/|\bsed\b[^|]*-i[^|]*codegen/logging/|\b(mv|cp)\b[^|]*codegen/logging/)'; then
            deny "BLOCKED by session-log-writer-only: raw Bash write into a cycle log is denied — write via codegen-log (init / section --body @- / section --role <role> / append --role <role>)."
            exit 0
        fi
    fi
    exit 0
    ;;
*)
    exit 0
    ;;
esac
