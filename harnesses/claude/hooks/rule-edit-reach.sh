#!/bin/bash
# rule-edit-reach.sh — PreToolUse Edit/Write/MultiEdit ADVISORY hook: before a
# role's write to a file under shared/rules/** lands, show how far the edit
# reaches — which rendered agent prompts include it, transitively, and by how
# much each one's committed byte headroom would be consumed.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Advises ANY role's Edit/Write/MultiEdit to shared/rules/** (or the codegen/rules symlink) with the fragment's transitive fan-out across rendered agent prompts and the projected byte overflow at each reached prompt, computed via prompt_size_budget.py --report --path. Delivered as hookSpecificOutput.additionalContext — the one channel a PreToolUse hook can use that the model actually reads. NEVER denies — cannot block, deny, or ask. Supersedes context-curator-guard.sh's deleted warn_if_over_cap (curator-only, own-row-only, stderr-only — proven unreachable by the model on an exit-0 PreToolUse hook).
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Declared fail-open: on an unparseable payload, an unresolvable repo root,
# or a render/measurement error, this hook emits NO advisory and exits 0 —
# an advisory that cannot be computed must never cost the role its turn. The
# fail-closed backstop is unchanged and lives elsewhere: `prompt-size-budget`
# (component of `make test`) still fails the build on a real overflow.
#
# Portability: no `stat`, no GNU/BSD-divergent tool. Byte arithmetic is
# `wc -c` and python3; path resolution reuses hooks_realpath (pure bash).

set -u
source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input
debug_log rule-edit-reach "tool=$TOOL_NAME file=$FILE_PATH"

case "$TOOL_NAME" in Edit | Write | MultiEdit) ;; *) exit 0 ;; esac
[ -z "$FILE_PATH" ] && exit 0

# Resolve the real (symlink-free) path — an edit may arrive via the
# codegen/rules symlink (curator's write surface) or the direct
# shared/rules/** path (every other role's write surface).
real_path=$(hooks_realpath "$FILE_PATH") || exit 0
[ -z "$real_path" ] && exit 0

# Walk up from the resolved path looking for templates/generator/
# prompt_size_budget.py — that directory is the repo root. Mirrors
# context-curator-guard.sh's own walk-up (this hook is installed outside the
# repo, at ~/.claude/hooks/, so $(dirname "$0") cannot reach it).
root="$real_path"
psb_script=""
while [ "$root" != "/" ] && [ -n "$root" ]; do
    root=$(dirname "$root")
    if [ -f "$root/templates/generator/prompt_size_budget.py" ]; then
        psb_script="$root/templates/generator/prompt_size_budget.py"
        break
    fi
done
[ -z "$psb_script" ] && exit 0

rel_path="${real_path#"$root"/}"
# Only shared/rules/** is in scope — a resolved path outside it is not this
# hook's concern (out-of-scope edit, or the symlink resolved somewhere else).
case "$rel_path" in
shared/rules/*) ;;
*) exit 0 ;;
esac

# Derive added bytes from the tool payload. Edit: new minus old. MultiEdit:
# summed over edits[]. Write: content size minus on-disk size (0 if the file
# does not yet exist — a brand-new rule file's whole content is the delta).
added_bytes=0
case "$TOOL_NAME" in
Edit)
    new_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) || exit 0
    old_string=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null) || exit 0
    [ -z "$new_string" ] && [ -z "$old_string" ] && exit 0
    new_b=$(printf '%s' "$new_string" | wc -c | tr -d ' ')
    old_b=$(printf '%s' "$old_string" | wc -c | tr -d ' ')
    added_bytes=$((new_b - old_b))
    ;;
MultiEdit)
    edits_json=$(printf '%s' "$RAW_INPUT" | jq -c '.tool_input.edits // []' 2>/dev/null) || exit 0
    [ -z "$edits_json" ] && exit 0
    [ "$edits_json" = "[]" ] && exit 0
    old_blob=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.old_string] | join("")' 2>/dev/null) || exit 0
    new_blob=$(printf '%s' "$RAW_INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("")' 2>/dev/null) || exit 0
    old_b=$(printf '%s' "$old_blob" | wc -c | tr -d ' ')
    new_b=$(printf '%s' "$new_blob" | wc -c | tr -d ' ')
    added_bytes=$((new_b - old_b))
    ;;
Write)
    content=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null) || exit 0
    [ -z "$content" ] && exit 0
    new_b=$(printf '%s' "$content" | wc -c | tr -d ' ')
    on_disk=0
    if [ -f "$real_path" ]; then
        on_disk=$(wc -c <"$real_path" 2>/dev/null | tr -d ' ')
        [ -z "$on_disk" ] && on_disk=0
    fi
    added_bytes=$((new_b - on_disk))
    ;;
esac

# A net-shrinking or no-op edit never overflows anything it didn't already
# overflow — nothing useful to advise. Only a net-additive edit can newly
# breach a downstream prompt's headroom.
if [ "$added_bytes" -le 0 ]; then
    exit 0
fi

report_text=$(cd "$root" && python3 templates/generator/prompt_size_budget.py --report --path "$rel_path" --added-bytes "$added_bytes" 2>/dev/null)
report_rc=$?
[ "$report_rc" -ne 0 ] && exit 0
[ -z "$report_text" ] && exit 0

advise "rule-edit-reach: $report_text"
exit 0
