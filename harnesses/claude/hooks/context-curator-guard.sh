#!/bin/bash
# context-curator-guard.sh — PreToolUse hook for context-curator.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: AGENT_TYPE
# role: context-curator
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Restricts Edit/Write/MultiEdit to the curator's allowed write surface:
#   - project context/**: context/** relative to CWD
#   - rules: codegen/rules/** (symlink to shared/rules; used by all curators)
#   - session logs: codegen/logging/** relative to CWD
#
# All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-curator-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

# warn_if_over_cap — projects post-write line count and prints a stderr warning
# if the write would exceed the STYLE_GUIDE tier cap for rule files.
# NEVER denies — always returns 0 (warn-only).
# Tier caps mirror STYLE_GUIDE.md: _core/ segment → 50; roles/ or stacks/ → 150.
# Skips silently on: MultiEdit, unparseable payload, any jq/file error.
warn_if_over_cap() {
    # MultiEdit payload has no single old/new_string — skip (fail-open).
    if [ "$TOOL_NAME" = "MultiEdit" ]; then
        return 0
    fi

    # Derive tier cap from path segments.
    local cap=0
    if printf '%s' "$FILE_PATH" | grep -qE '(^|/)_core(/|$)'; then
        cap=50
    elif printf '%s' "$FILE_PATH" | grep -qE '(^|/)(roles|stacks)(/|$)'; then
        cap=150
    else
        # No cap for this path tier.
        return 0
    fi

    # Project post-write line count.
    local projected=0
    if [ "$TOOL_NAME" = "Write" ]; then
        # Write replaces the file entirely — project from content newlines.
        local content
        content=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null) || return 0
        projected=$(printf '%s' "$content" | tr -cd '\n' | wc -c | tr -d ' ')
    elif [ "$TOOL_NAME" = "Edit" ]; then
        # Edit: current_wc_l - newlines(old_string) + newlines(new_string)
        local new_string old_string
        new_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) || return 0
        old_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null) || return 0
        # Missing new_string means unparseable — fail-open.
        if [ -z "$new_string" ] && [ -z "$old_string" ]; then
            return 0
        fi
        local current_lines
        current_lines=$(wc -l <"$FILE_PATH" 2>/dev/null | tr -d ' ') || current_lines=0
        local old_nl new_nl
        old_nl=$(printf '%s' "$old_string" | tr -cd '\n' | wc -c | tr -d ' ')
        new_nl=$(printf '%s' "$new_string" | tr -cd '\n' | wc -c | tr -d ' ')
        projected=$((current_lines - old_nl + new_nl))
    else
        return 0
    fi

    if [ "$projected" -gt "$cap" ]; then
        printf >&2 '[context-curator-guard] WARNING: %s — projected %d lines exceeds tier cap %d. Compress or relocate the verbose example to context/*.md.\n' \
            "$FILE_PATH" "$projected" "$cap"
    fi
    return 0
}

# Only gate the context-curator; all other agents pass through.
case "$AGENT_TYPE" in
context-curator) ;;
*)
    exit 0
    ;;
esac

case "$TOOL_NAME" in
Edit | Write | MultiEdit) ;;
*)
    exit 0
    ;;
esac

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Allowed: project context/** (relative or absolute, any project root)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)context/'; then
    exit 0
fi

# Allowed: codegen/rules/** (symlink to shared/rules)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)codegen/rules(/|$)'; then
    warn_if_over_cap
    exit 0
fi

# Allowed: codegen/logging/** (session logs)
if printf '%s' "$FILE_PATH" | grep -qE '(^|/)codegen/logging/'; then
    exit 0
fi

# Everything else is denied for context-curator.
deny "BLOCKED by context-curator-guard: $FILE_PATH is outside the curator's allowed write surface. Curator may only write to: context/**, codegen/rules/**, codegen/logging/**."
exit 0
