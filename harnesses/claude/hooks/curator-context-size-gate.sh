#!/bin/bash
# curator-context-size-gate.sh — PreToolUse Edit/Write/MultiEdit hook:
# deny a context-curator write to context/<file>.md when the projected
# post-write byte size would exceed the 40,960-byte (40k) cap.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Denies ANY role's Edit/Write/MultiEdit to context/<file>.md when the projected post-write byte size exceeds the 40,960-byte cap, so the over-cap file is fixed in the writer's own turn — where context/*.md is editable this turn — instead of failing later at commit on the committer, which cannot repair it. Composes with context-curator-guard (path surface, curator-only) and the commit-time context-file-size-gate backstop.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Gates ANY role's write to context/*.md — any role may legitimately edit
# context files (e.g. developer, when planner marks one (EDIT)/(NEW)).
# Unparseable payloads fail open (backstop context-file-size-gate.sh catches
# at commit). MultiEdit sums all edits[] deltas rather than failing open.

set -u
source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input
debug_log curator-context-size-gate "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"
CAP=40960

case "$TOOL_NAME" in Edit | Write | MultiEdit) ;; *) exit 0 ;; esac
[ -z "$FILE_PATH" ] && exit 0
# Only direct-child context/<file>.md (parity with commit-time gate).
printf '%s' "$FILE_PATH" | grep -qE '(^|/)context/[^/]+\.md$' || exit 0

projected=0
if [ "$TOOL_NAME" = "MultiEdit" ]; then
    edits_json=$(printf '%s' "$RAW_INPUT" | jq -c '.tool_input.edits // []' 2>/dev/null) || exit 0
    [ -z "$edits_json" ] && exit 0
    [ "$edits_json" = "[]" ] && exit 0
    old_blob=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.old_string] | join("")' 2>/dev/null) || exit 0
    new_blob=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("")' 2>/dev/null) || exit 0
    on_disk=0
    if [ -f "$FILE_PATH" ]; then
        on_disk=$(wc -c <"$FILE_PATH" 2>/dev/null | tr -d ' ')
        [ -z "$on_disk" ] && on_disk=0
    fi
    old_b=$(printf '%s' "$old_blob" | wc -c | tr -d ' ')
    new_b=$(printf '%s' "$new_blob" | wc -c | tr -d ' ')
    projected=$((on_disk - old_b + new_b))
    if [ "$projected" -gt "$CAP" ]; then
        deny "curator-context-size-gate: your MultiEdit to ${FILE_PATH} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. context/*.md is editable this turn — compress a stale/redundant bullet, relocate a verbose example to another context file, or split to a new context/*.md (add the matching PROJECT_CONTEXT.md Domain Context Files row). Get the file under 40960 bytes before finishing this cycle."
    fi
    exit 0
fi
if [ "$TOOL_NAME" = "Write" ]; then
    content=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null) || exit 0
    # empty content = unparseable/absent → fail open
    [ -z "$content" ] && exit 0
    projected=$(printf '%s' "$content" | wc -c | tr -d ' ')
else # Edit
    new_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) || exit 0
    old_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null) || exit 0
    [ -z "$new_string" ] && [ -z "$old_string" ] && exit 0
    on_disk=0
    if [ -f "$FILE_PATH" ]; then
        on_disk=$(wc -c <"$FILE_PATH" 2>/dev/null | tr -d ' ')
        [ -z "$on_disk" ] && on_disk=0
    fi
    old_b=$(printf '%s' "$old_string" | wc -c | tr -d ' ')
    new_b=$(printf '%s' "$new_string" | wc -c | tr -d ' ')
    projected=$((on_disk - old_b + new_b))
fi

if [ "$projected" -gt "$CAP" ]; then
    deny "curator-context-size-gate: your write to ${FILE_PATH} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. context/*.md is editable this turn — compress a stale/redundant bullet, relocate a verbose example to another context file, or split to a new context/*.md (add the matching PROJECT_CONTEXT.md Domain Context Files row). Get the file under 40960 bytes before finishing this cycle."
fi
exit 0
