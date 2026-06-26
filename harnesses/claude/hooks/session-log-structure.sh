#!/bin/bash
# session-log-structure.sh — PreToolUse Edit|Write|MultiEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# rationale: Enforces canonical session-log section ORDER (non-decreasing phase rank) and NO-CLOBBER (an Edit/Write must not remove any existing `## ` header), preventing scramble and the full-file-Write data-loss that drops Plan/Delegation content.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Denies Edit/Write/MultiEdit to codegen/logging/*.md that either:
#   (a) reorder recognized section headers outside the canonical phase order, or
#   (b) remove a `## ` header that already exists on disk (no-clobber).
#
# Bypasses debug/shape/ops. Fails open on unreadable disk file.
#
# LIMITATION: mid-insert order under-detection — when an Edit inserts a new
# header in the middle of existing content (not appended at EOF), this hook
# checks the merged disk+new_string content for order violations but cannot
# detect the exact insertion position relative to disk content. The check will
# catch gross inversions (reviewer before developer) but may miss subtle
# mid-sequence insertions in complex multi-section logs.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log session-log-structure "tool=$TOOL_NAME file=${FILE_PATH:-}"

# Investigative-mode bypass (sibling-guard convention).
_role=$(resolve_role)
case "$_role" in debug | shape | ops) exit 0 ;; esac

# Only guard Edit|Write|MultiEdit.
case "$TOOL_NAME" in Edit | Write | MultiEdit) ;; *) exit 0 ;; esac

# Only gate session log files.
if ! printf '%s' "$FILE_PATH" | grep -qE 'codegen/logging/.*\.md$'; then
    exit 0
fi

# rank_of <line> — print numeric rank for recognized ## headers; empty for unknown.
# NOTE: only ## (H2) headers participate — single # (H1 title) lines are skipped
# to avoid false-positives from code-block comment lines starting with "# ".
rank_of() {
    local line="$1"
    case "$line" in
    "## Version Stamp") printf '1' ;;
    "## Rules Loaded"*) printf '2' ;;
    "## Plan"*) printf '3' ;;
    "## Slices"*) printf '3' ;;
    "## Delegation Timeline"*) printf '4' ;;
    "## Files Modified"*) printf '5' ;;
    "## developer-"*" Section"*) printf '6' ;;
    "## reviewer-"*" Section"*) printf '8' ;;
    "## context-curator Section"*) printf '9' ;;
    "## committer Section"*) printf '10' ;;
    *) printf '' ;;
    esac
}

# check_order <blob> — scan lines; deny if any recognized header rank < previous rank.
# Outputs denial message on violation; silent on pass.
check_order() {
    local blob="$1"
    local prev_rank=0
    local offender=""
    while IFS= read -r line; do
        # Only check H2 (## ) header lines; skip H1 (#) and deeper (###).
        case "$line" in
        "## "*)
            local rank
            rank=$(rank_of "$line")
            [ -z "$rank" ] && continue
            if [ "$rank" -lt "$prev_rank" ]; then
                offender="$line"
                break
            fi
            prev_rank="$rank"
            ;;
        esac
    done <<EOF
$blob
EOF
    if [ -n "$offender" ]; then
        printf '%s' "$offender"
    fi
}

# read_h2_headers <file> — print all ## header lines from a file.
read_h2_headers() {
    grep -E '^## ' "$1" 2>/dev/null || true
}

case "$TOOL_NAME" in
Write)
    content=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // ""')

    # No-clobber check: if file already exists, every disk ## header must appear in content.
    if [ -f "$FILE_PATH" ] && [ -r "$FILE_PATH" ]; then
        while IFS= read -r hdr; do
            [ -z "$hdr" ] && continue
            if ! printf '%s' "$content" | grep -qxF "$hdr"; then
                deny "BLOCKED by session-log-structure: Write would remove existing header \"$hdr\" — use Edit to update sections, never full-file Write on an existing log."
                exit 0
            fi
        done <<EOF
$(read_h2_headers "$FILE_PATH")
EOF
    fi

    # Order check on the full content.
    offender=$(check_order "$content")
    if [ -n "$offender" ]; then
        deny "BLOCKED by session-log-structure: header \"$offender\" appears out of canonical phase order — see session-log.md § Canonical Section Order."
        exit 0
    fi
    ;;

Edit | MultiEdit)
    # Collect old_string(s) and new_string(s).
    if [ "$TOOL_NAME" = "Edit" ]; then
        old=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.old_string // ""')
        new=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""')
    else
        old=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.old_string // ""] | join("\n")')
        new=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")')
    fi

    # No-clobber check: any ## header present in old_string must also appear in new_string.
    while IFS= read -r hdr; do
        [ -z "$hdr" ] && continue
        if ! printf '%s' "$new" | grep -qxF "$hdr"; then
            deny "BLOCKED by session-log-structure: Edit removes header \"$hdr\" from old_string without preserving it in new_string — session log headers must not be deleted."
            exit 0
        fi
    done <<EOF
$(printf '%s' "$old" | grep -E '^## ' || true)
EOF

    # Order check: simulate the post-edit file and verify order.
    disk_content=""
    if [ -f "$FILE_PATH" ] && [ -r "$FILE_PATH" ]; then
        disk_content=$(cat "$FILE_PATH")
    fi
    # File absent → fail open (allow); only check if disk readable.
    if [ -n "$disk_content" ] || [ -f "$FILE_PATH" ]; then
        simulated="$disk_content"
        if [ "$TOOL_NAME" = "Edit" ]; then
            if [ -z "$old" ]; then
                simulated="${simulated}${new}"
            else
                simulated="${simulated/$old/$new}"
            fi
        else
            # MultiEdit: fold edits in array order.
            edit_count=$(printf '%s' "$RAW_INPUT" | jq '.tool_input.edits | length')
            i=0
            while [ "$i" -lt "$edit_count" ]; do
                e_old=$(printf '%s' "$RAW_INPUT" | jq -r ".tool_input.edits[$i].old_string // \"\"")
                e_new=$(printf '%s' "$RAW_INPUT" | jq -r ".tool_input.edits[$i].new_string // \"\"")
                if [ -z "$e_old" ]; then
                    simulated="${simulated}${e_new}"
                else
                    simulated="${simulated/$e_old/$e_new}"
                fi
                i=$((i + 1))
            done
        fi
        offender=$(check_order "$simulated")
        if [ -n "$offender" ]; then
            deny "BLOCKED by session-log-structure: header \"$offender\" appears out of canonical phase order — see session-log.md § Canonical Section Order."
            exit 0
        fi
    fi
    ;;
esac

exit 0
