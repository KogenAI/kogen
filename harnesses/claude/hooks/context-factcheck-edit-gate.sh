#!/bin/bash
# context-factcheck-edit-gate.sh — PreToolUse Edit/Write/MultiEdit hook: deny
# ANY role's write to an orientation doc (CLAUDE.md, AGENTS.md,
# PROJECT_CONTEXT.md, codegen/PROJECT_CONTEXT.md, context/*.md) when the
# PROJECTED post-write content contains a factcheck violation (named-path
# claim, count-anchor mismatch, or `_`->`*` identifier corruption).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Denies ANY role's Edit/Write/MultiEdit to an orientation doc (CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md, codegen/PROJECT_CONTEXT.md, context/*.md) when the PROJECTED post-write content contains a factcheck violation (named-path claim, count-anchor mismatch, or `_`->`*` identifier corruption), so it is fixed in the writer's own turn — where the doc is editable this turn — instead of failing later at a downstream role (committer) that cannot repair it. Mirrors curator-context-size-gate. Supersedes the deleted context-factcheck-curator-stop (dead SubagentStop under the loop) and context-factcheck-guard (commit-time dead-end).
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Projection mechanic: materializes the projected post-write body for the
# target doc, mirrors it into a throwaway git-initialized temp directory at
# the SAME relative path (plus a placeholder PROJECT_CONTEXT.md so the
# layout-detection in context-factcheck-scan.sh resolves), then runs the
# UNCHANGED shared scan primitive (lib/context-factcheck-scan.sh) against
# that mirror. This keeps the scan logic single-sourced with the in-loop
# Elixir step and the (deleted) interactive SubagentStop hook.
#
# Allows (fail-open):
#   - Non-Edit/Write/MultiEdit tools
#   - FILE_PATH not an orientation doc
#   - Unparseable tool_input (jq failures) — backstop is
#     run_curator_doc_check (in-loop, post-curator, end-of-turn)
#   - Scan reports clean

set -u
source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input
debug_log context-factcheck-edit-gate "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH"

case "$TOOL_NAME" in Edit | Write | MultiEdit) ;; *) exit 0 ;; esac
[ -z "$FILE_PATH" ] && exit 0

# Resolve a repo-relative doc path matching the orientation-doc grammar.
# Determine repo root first (best-effort; CWD from parse_input).
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

# Canonicalize both sides before the prefix strip — repo_root came back from
# `git rev-parse --show-toplevel`, which resolves symlinks (e.g. macOS
# /tmp -> /private/tmp); abs_path did not go through the same resolution.
abs_path_real=$(hooks_realpath "$abs_path")
[ -n "$abs_path_real" ] && abs_path="$abs_path_real"

rel_path="${abs_path#"$repo_root"/}"
# Not under repo_root at all -> out of scope.
[ "$rel_path" = "$abs_path" ] && exit 0

case "$rel_path" in
CLAUDE.md | AGENTS.md | PROJECT_CONTEXT.md | codegen/PROJECT_CONTEXT.md) ;;
context/*.md)
    # Only direct children of context/ (parity with sibling doc gates).
    case "$rel_path" in
    context/*/*) exit 0 ;;
    esac
    ;;
*) exit 0 ;;
esac

# Materialize projected content for the target doc.
projected=""
case "$TOOL_NAME" in
Write)
    projected=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null) || exit 0
    ;;
Edit)
    old_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null) || exit 0
    new_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null) || exit 0
    [ -z "$old_string" ] && [ -z "$new_string" ] && exit 0
    if [ -f "$abs_path" ]; then
        on_disk=$(cat "$abs_path" 2>/dev/null)
    else
        on_disk=""
    fi
    # Single-occurrence replace (mirrors Edit tool semantics closely enough
    # for a projection — exact multi-match ambiguity is not our concern here).
    projected=$(printf '%s' "$on_disk" | awk -v old="$old_string" -v new="$new_string" '
        BEGIN { done = 0 }
        {
            line = $0
            if (!done && index(line, old) > 0 && old != "") {
                sub(old, new, line)
                done = 1
            }
            print line
        }
    ')
    ;;
MultiEdit)
    edits_json=$(printf '%s' "$RAW_INPUT" | jq -c '.tool_input.edits // []' 2>/dev/null) || exit 0
    [ -z "$edits_json" ] || [ "$edits_json" = "[]" ] && exit 0
    if [ -f "$abs_path" ]; then
        projected=$(cat "$abs_path" 2>/dev/null)
    else
        projected=""
    fi
    n=$(printf '%s' "$edits_json" | jq 'length' 2>/dev/null) || exit 0
    i=0
    while [ "$i" -lt "$n" ]; do
        old_string=$(printf '%s' "$edits_json" | jq -r ".[$i].old_string // empty" 2>/dev/null) || exit 0
        new_string=$(printf '%s' "$edits_json" | jq -r ".[$i].new_string // empty" 2>/dev/null) || exit 0
        if [ -n "$old_string" ]; then
            projected=$(printf '%s' "$projected" | awk -v old="$old_string" -v new="$new_string" '
                BEGIN { done = 0 }
                {
                    line = $0
                    if (!done && index(line, old) > 0) {
                        sub(old, new, line)
                        done = 1
                    }
                    print line
                }
            ')
        fi
        i=$((i + 1))
    done
    ;;
esac

[ -z "$projected" ] && exit 0

# Mirror the projected doc into a throwaway git-initialized temp dir at the
# same relative path, plus a placeholder PROJECT_CONTEXT.md so the shared
# scan's layout-detection resolves.
tmp_root=$(mktemp -d) || exit 0
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/$(dirname "$rel_path")" 2>/dev/null || exit 0
printf '%s' "$projected" >"$tmp_root/$rel_path" 2>/dev/null || exit 0
if [ "$rel_path" != "PROJECT_CONTEXT.md" ]; then
    : >"$tmp_root/PROJECT_CONTEXT.md"
fi
(cd "$tmp_root" && git init -q) >/dev/null 2>&1 || exit 0

# DOC CONTENT comes from the projection mirror; PATH CLAIMS and count probes
# resolve against the REAL repo root. Passing $tmp_root as repo_root (as this
# hook did until now) made every valid path claim in the doc a false violation
# — nothing exists in the mirror.
scan_out=$(FACTCHECK_DOC_ROOT="$tmp_root" bash "$(dirname "$0")/lib/context-factcheck-scan.sh" "$repo_root" "$rel_path")
scan_rc=$?

if [ "$scan_rc" -eq 1 ] && [ -n "$scan_out" ]; then
    # scan_out lines are prefixed "context-factcheck-scan: <doc>:<linenum> ..."
    # — rewrite the tmp-root-relative doc path prefix if needed (it already
    # is $rel_path, so no rewrite required).
    deny "$scan_out
context/*.md is editable this turn — fix before finishing this cycle."
fi
exit 0
