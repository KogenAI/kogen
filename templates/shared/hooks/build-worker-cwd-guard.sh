#!/bin/bash
# build-worker-cwd-guard.sh — PreToolUse hook scoped to the BuildWorker
# orchestrator only.
#
# Goal: enforce that the orchestrator (top-level claude --print invocation in
# the user-app cwd) cannot Read/Write/Edit files outside the user app directory,
# and cannot run Bash commands referencing absolute paths outside it.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log build-worker-cwd-guard "tool=$TOOL_NAME agent_id=$AGENT_ID agent_type=$AGENT_TYPE"

# ── Subagent escape hatch ────────────────────────────────────────────────────
# Any non-empty agent_id means we're inside a subagent; pass through.
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

# ── Determine project dir ────────────────────────────────────────────────────
project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# ── Platform-repo bypass ─────────────────────────────────────────────────────
# Real apps_root values (source-of-truth: combobulate config/{test,dev,runtime}.exs):
#   - ~/.combobulate_test_apps/part<N>/apps  (test partitions, MIX_TEST_PARTITION)
#   - /home/combobulate/apps                  (production, APPS_ROOT env)
#   - */AppBuilder/apps                       (local dev — host-dependent prefix)
case "$project_dir" in
*/.combobulate_test_apps/*/apps/*) ;; # test partition workspace
/home/combobulate/apps/*) ;;          # production apps_root
*/AppBuilder/apps/*) ;;               # local dev apps_root
*) exit 0 ;;                          # platform repo or other non-user-app context — no-op
esac
real_project_dir=$(hooks_realpath "$project_dir")
project_prefix="${real_project_dir%/}/"

# ── Whitelist (resolved once) ────────────────────────────────────────────────
home_dir=$(hooks_realpath "$HOME")
whitelist=(
    "/private/tmp"
    "/tmp"
    "/dev/null"
    "$home_dir/.combobulate_phoenix_seed"
    "$home_dir/.phx_new_cache"
)

is_allowed_path() {
    local p="$1"
    # Empty path: let the tool handle it.
    [ -z "$p" ] && return 0
    local real
    real=$(hooks_realpath "$p")
    # Project dir or within it.
    [ "$real" = "$real_project_dir" ] && return 0
    case "$real" in "${project_prefix}"*) return 0 ;; esac
    # Whitelist entries.
    local w wp
    for w in "${whitelist[@]}"; do
        local wreal
        wreal=$(hooks_realpath "$w")
        [ "$real" = "$wreal" ] && return 0
        wp="${wreal%/}/"
        case "$real" in "${wp}"*) return 0 ;; esac
    done
    return 1
}

case "$TOOL_NAME" in
Read | Write | Edit | MultiEdit | NotebookEdit)
    if [ -z "$FILE_PATH" ]; then
        exit 0
    fi
    if is_allowed_path "$FILE_PATH"; then
        exit 0
    fi
    deny "BLOCKED by build-worker-cwd-guard: orchestrator $TOOL_NAME on $FILE_PATH is outside the user app dir $project_dir. Subagents may have broader access; the orchestrator does not."
    exit 0
    ;;

Bash)
    if [ -z "$COMMAND" ]; then
        exit 0
    fi

    # Deny relative path traversal (..).
    if printf '%s' "$COMMAND" | grep -qE '\.\./' ; then
        deny "BLOCKED by build-worker-cwd-guard: relative path traversal (..) forbidden — use absolute paths only"
        exit 0
    fi

    # Extract absolute path tokens.
    abs_paths=$(printf '%s' "$COMMAND" | grep -oE '/[^ "'"'"'`)]+' || true)

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue
        # Strip a trailing ; or , or ) the regex may have included.
        abs_path="${abs_path%[);,]}"
        if is_allowed_path "$abs_path"; then
            continue
        fi
        deny "BLOCKED by build-worker-cwd-guard: orchestrator Bash references $abs_path outside user app dir $project_dir"
        exit 0
    done <<<"$abs_paths"
    exit 0
    ;;
esac

exit 0
