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
    # Collect new_string(s).
    if [ "$TOOL_NAME" = "Edit" ]; then
        new=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""')
    else
        new=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")')
    fi
    # Self-duplicate within the payload.
    selfdup=$(section_headers "$new" | sort | uniq -d | head -n 1)
    if [ -n "$selfdup" ]; then
        deny "BLOCKED by session-log-no-duplicate-section: this Edit adds the header \"$selfdup\" more than once. Insert each \`## <role> Section\` exactly once."
        exit 0
    fi
    # Header in payload that already exists on disk → would duplicate.
    if [ -f "$FILE_PATH" ] && [ -r "$FILE_PATH" ]; then
        while IFS= read -r hdr; do
            [ -z "$hdr" ] && continue
            if grep -qxF "$hdr" "$FILE_PATH" 2>/dev/null; then
                deny "BLOCKED by session-log-no-duplicate-section: \"$hdr\" already exists in this log — do NOT re-add it; skip the header Edit and proceed to spawn (the presence guard is already satisfied)."
                exit 0
            fi
        done <<EOF
$(section_headers "$new")
EOF
    fi
    # File unreadable/absent → fail open (allow).
    ;;
esac

exit 0
