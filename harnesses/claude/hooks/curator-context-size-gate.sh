#!/bin/bash
# curator-context-size-gate.sh — PreToolUse Edit/Write/MultiEdit hook:
# deny ANY role's write to context/<file>.md, PROJECT_CONTEXT.md, or
# codegen/PROJECT_CONTEXT.md when the projected post-write byte size would
# exceed the 40,960-byte (40k) cap.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Denies ANY role's Edit/Write/MultiEdit to context/<file>.md, PROJECT_CONTEXT.md, or codegen/PROJECT_CONTEXT.md when the projected post-write byte size exceeds the 40,960-byte cap, so the over-cap file is fixed in the writer's own turn — where the doc is editable this turn — instead of failing later at commit on the committer, which cannot repair it. Composes with context-curator-guard (path surface, curator-only).
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Gates ANY role's write to context/*.md, PROJECT_CONTEXT.md, or
# codegen/PROJECT_CONTEXT.md — any role may legitimately edit these docs
# (e.g. developer, when planner marks one (EDIT)/(NEW)). This is the ONLY
# size enforcement on these paths — there is no commit-time backstop.
# Unparseable payloads fail open. MultiEdit sums all edits[] deltas rather
# than failing open.
#
# CLAUDE.md/AGENTS.md are deliberately NOT gated here: in downstream repos
# those are rendered symlinks whose bytes are decided by a .j2 template at
# render time, not by the editing agent — a byte cap on a rendered artifact
# would deny a write the agent cannot repair in-turn.

set -u
source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input
debug_log curator-context-size-gate "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"
CAP=40960

case "$TOOL_NAME" in Edit | Write | MultiEdit) ;; *) exit 0 ;; esac
[ -z "$FILE_PATH" ] && exit 0

# Resolve a repo-relative path so PROJECT_CONTEXT.md at repo root (and
# codegen/PROJECT_CONTEXT.md) can be matched, not just context/<file>.md.
project_dir="${CWD:-$PWD}"
if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi
repo_root=$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)
[ -z "$repo_root" ] && exit 0

case "$FILE_PATH" in
/*) abs_path="$FILE_PATH" ;;
*) abs_path="$project_dir/$FILE_PATH" ;;
esac

abs_path_real=$(hooks_realpath "$abs_path")
[ -n "$abs_path_real" ] && abs_path="$abs_path_real"

rel_path="${abs_path#"$repo_root"/}"
# Not under repo_root at all -> out of scope.
[ "$rel_path" = "$abs_path" ] && exit 0

is_root_doc=0
case "$rel_path" in
PROJECT_CONTEXT.md | codegen/PROJECT_CONTEXT.md) is_root_doc=1 ;;
context/*.md)
    # Only direct children of context/ (parity with sibling doc gates).
    case "$rel_path" in
    context/*/*) exit 0 ;;
    esac
    ;;
*) exit 0 ;;
esac

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
        if [ "$is_root_doc" = "1" ]; then
            deny "curator-context-size-gate: your MultiEdit to ${FILE_PATH} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. ${FILE_PATH} is editable this turn — compress a Domain Context Files row's keyword cell or relocate prose into the context/*.md file that row points at. Get the file under 40960 bytes before finishing this cycle."
        else
            deny "curator-context-size-gate: your MultiEdit to ${FILE_PATH} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. context/*.md is editable this turn — compress a stale/redundant bullet, relocate a verbose example to another context file, or split to a new context/*.md (add the matching PROJECT_CONTEXT.md Domain Context Files row). Get the file under 40960 bytes before finishing this cycle."
        fi
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
    if [ "$is_root_doc" = "1" ]; then
        deny "curator-context-size-gate: your write to ${FILE_PATH} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. ${FILE_PATH} is editable this turn — compress a Domain Context Files row's keyword cell or relocate prose into the context/*.md file that row points at. Get the file under 40960 bytes before finishing this cycle."
    else
        deny "curator-context-size-gate: your write to ${FILE_PATH} would make it ${projected} bytes, over the ${CAP}-byte (40k) cap. context/*.md is editable this turn — compress a stale/redundant bullet, relocate a verbose example to another context file, or split to a new context/*.md (add the matching PROJECT_CONTEXT.md Domain Context Files row). Get the file under 40960 bytes before finishing this cycle."
    fi
fi
exit 0
