#!/bin/bash
# build-worker-cwd-guard.sh — PreToolUse hook scoped to the BuildWorker
# orchestrator only.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Write|Edit|MultiEdit|Read|Monitor
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
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
# Real apps_root values: from OCG_APPS_ROOT env (set by the consuming platform).
# If OCG_APPS_ROOT is unset, codegen cannot know the boundary — allow everything
# (this session is not a managed build worker).
apps_root="${OCG_APPS_ROOT:-}"
if [ -z "$apps_root" ]; then
    exit 0
fi
case "$project_dir" in
"${apps_root%/}"/*) ;; # within the consumer apps root — enforcement active
*) exit 0 ;;           # outside apps root — not a managed build worker; no-op
esac
real_project_dir=$(hooks_realpath "$project_dir")
project_prefix="${real_project_dir%/}/"

# ── Whitelist (resolved once) ────────────────────────────────────────────────
home_dir=$(hooks_realpath "$HOME")
whitelist=(
    "/private/tmp"
    "/tmp"
    "/dev/null"
    "$home_dir/.phx_new_cache"
)
# Add OCG_PHOENIX_SEED_DIR to whitelist only when set.
seed_dir="${OCG_PHOENIX_SEED_DIR:-}"
if [ -n "$seed_dir" ]; then
    whitelist+=("$seed_dir")
fi
# Add OCG_USER_FILES_DIR to whitelist only when set (consumer upload dir).
user_files_dir="${OCG_USER_FILES_DIR:-}"
if [ -n "$user_files_dir" ]; then
    whitelist+=("$user_files_dir")
fi

is_allowed_path() {
    local p="$1"
    # Empty path: this is the Bash abs-path-token loop path (an empty token
    # from splitting a command string is a legitimate skip of a non-path
    # match, NOT a file-bearing tool anomaly) — distinct from the
    # Read|Write|Edit|MultiEdit|NotebookEdit file-tool arm below, which
    # denies on empty FILE_PATH. Let the tool handle it here.
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
    # fail-closed: matcher is file-bearing; empty path is anomalous, not a
    # legitimate skip (interaction-composition proof verified).
    if [ -z "$FILE_PATH" ]; then
        deny "BLOCKED by build-worker-cwd-guard: empty/unresolvable file path for orchestrator $TOOL_NAME inside a managed build worker (cwd under OCG_APPS_ROOT). File-bearing tool with no path is anomalous; failing closed."
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
    if printf '%s' "$COMMAND" | grep -qE '\.\./'; then
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
