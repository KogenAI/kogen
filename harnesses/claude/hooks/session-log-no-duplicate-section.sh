#!/bin/bash
# session-log-no-duplicate-section.sh — PreToolUse Edit|Write|MultiEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# rationale: Denies session-log Edit/Write payloads that would create a duplicate `## <role> Section` header, preventing the mid-cycle `replace_all is false` stall
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Denies any Edit/Write/MultiEdit to codegen/logging/*.md that would yield a
# SECOND copy of any "## <X> Section" header. Fires for orchestrator and
# subagents alike. Bypasses debug/shape/ops. Fails open on unreadable log.
#
# For Edit/MultiEdit: RESULT SIMULATION — applies old_string→new_string to a
# copy of the on-disk content (FIRST occurrence only; empty old_string →
# append new_string) and denies iff any role-section header appears 2+ times
# in the simulated result. A follow-up that re-states a pre-placed placeholder
# header nets zero new copies and is ALLOWED. MultiEdit folds edits in order.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log session-log-no-duplicate-section "tool=$TOOL_NAME file=${FILE_PATH:-}"

# Investigative-mode bypass (sibling-guard convention).
_role=$(resolve_role)
case "$_role" in debug | shape | ops) exit 0 ;; esac

# Only guard Edit|Write|MultiEdit.
case "$TOOL_NAME" in Edit | Write | MultiEdit) ;; *) exit 0 ;; esac

# Only gate session log files.
if ! printf '%s' "$FILE_PATH" | grep -qE 'codegen/logging/.*\.md$'; then
    exit 0
fi

# Extract "## <X> Section" header lines from a blob (one per line).
section_headers() {
    printf '%s' "$1" | grep -oE '^## .+ Section$' 2>/dev/null
}

# splice_first <var> <old> <new> — literal first-occurrence replace of $old with
# $new in $var. bash-3.2-safe: uses %% / # strip operators with a QUOTED pattern
# (no ${var/$pat/repl}, which misparses a #-leading $pat on bash 3.2.57 and
# silently no-ops). Containment-guarded so a NON-MATCHING $old leaves $var
# unchanged (an unguarded splice would duplicate $var on no-match). Caller MUST
# handle empty $old separately (append), never pass "" here.
splice_first() {
    local v="$1" o="$2" n="$3"
    case "$v" in
    *"$o"*) printf '%s' "${v%%"$o"*}$n${v#*"$o"}" ;;
    *) printf '%s' "$v" ;;
    esac
}

case "$TOOL_NAME" in
Write)
    content=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // ""')
    # Deny if any header appears 2+ times in the content.
    dup=$(section_headers "$content" | sort | uniq -d | head -n 1)
    if [ -n "$dup" ]; then
        deny "BLOCKED by session-log-no-duplicate-section: Write content contains a duplicate header \"$dup\". Each \`## <role> Section\` must appear exactly once — remove the extra copy and rewrite."
        exit 0
    fi
    ;;
Edit | MultiEdit)
    # Fast-path: self-duplicate within the payload (applies even if disk unreadable).
    if [ "$TOOL_NAME" = "Edit" ]; then
        new=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""')
    else
        new=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")')
    fi
    selfdup=$(section_headers "$new" | sort | uniq -d | head -n 1)
    if [ -n "$selfdup" ]; then
        deny "BLOCKED by session-log-no-duplicate-section: this Edit adds the header \"$selfdup\" more than once. Insert each \`## <role> Section\` exactly once."
        exit 0
    fi

    # Result simulation: apply old→new to on-disk content, then check for dups.
    # Fail open (allow) when file is unreadable/absent.
    if [ -f "$FILE_PATH" ] && [ -r "$FILE_PATH" ]; then
        disk=$(cat "$FILE_PATH")
        simulated="$disk"
        if [ "$TOOL_NAME" = "Edit" ]; then
            old=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.old_string // ""')
            if [ -z "$old" ]; then
                # Empty old_string → append new_string.
                simulated="${simulated}${new}"
            else
                # Replace FIRST occurrence only; bash-3.2-safe splice helper.
                simulated=$(splice_first "$simulated" "$old" "$new")
            fi
        else
            # MultiEdit: fold edits sequentially in array order.
            edit_count=$(printf '%s' "$RAW_INPUT" | jq '.tool_input.edits | length')
            i=0
            while [ "$i" -lt "$edit_count" ]; do
                e_old=$(printf '%s' "$RAW_INPUT" | jq -r ".tool_input.edits[$i].old_string // \"\"")
                e_new=$(printf '%s' "$RAW_INPUT" | jq -r ".tool_input.edits[$i].new_string // \"\"")
                if [ -z "$e_old" ]; then
                    simulated="${simulated}${e_new}"
                else
                    simulated=$(splice_first "$simulated" "$e_old" "$e_new")
                fi
                i=$((i + 1))
            done
        fi
        dup=$(section_headers "$simulated" | sort | uniq -d | head -n 1)
        if [ -n "$dup" ]; then
            deny "BLOCKED by session-log-no-duplicate-section: \"$dup\" already exists in this log — do NOT re-add it; skip the header Edit and proceed to spawn (the presence guard is already satisfied). Switch to \`(pass N)\` if intentional re-spawn."
            exit 0
        fi
    fi
    # File unreadable/absent → fail open (allow).
    ;;
esac

exit 0
