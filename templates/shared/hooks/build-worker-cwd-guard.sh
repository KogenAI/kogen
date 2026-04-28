#!/bin/bash
# build-worker-cwd-guard.sh — PreToolUse hook scoped to the BuildWorker
# orchestrator only.
#
# Goal: enforce that the orchestrator (top-level claude --print invocation in
# the user-app cwd) cannot Read/Write/Edit files outside the user app directory,
# and cannot run Bash commands referencing absolute paths outside it.
#
# Subagents are NOT gated here — they may legitimately need broader access
# (planner reading hexdocs, VE reading make output in /tmp, committer running
# git operations, etc.).
#
# How "orchestrator vs subagent" is detected (verified on Claude Code 2.1.119):
#   - PreToolUse stdin contains agent_id and agent_type ONLY when fired
#     inside a subagent. Top-level/orchestrator calls have NEITHER field.
#   - An empty agent_id is the discriminator. NOT agent_name (legacy field
#     that no longer exists in current Claude Code; see pre-commit-guard.sh's
#     stale TODO comment).
#
# Whitelisted system paths the orchestrator is still allowed to touch:
#   /tmp, /private/tmp, /dev/null, ~/.combobulate_phoenix_seed, ~/.phx_new_cache
#
# Exit codes:
#   0 — allow the tool call
#   2 — block (Claude Code PreToolUse convention; stderr fed back to model)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // ""')
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# Debug logging
if [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ] || [ -n "${COMBOBULATE_BWG_DEBUG:-}" ]; then
    printf '%s tool=%s agent_id=%s agent_type=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_id" "$agent_type" \
        >>/tmp/build-worker-cwd-guard-debug.log 2>/dev/null || true
fi

# ── Subagent escape hatch ────────────────────────────────────────────────────
# Any non-empty agent_id means we're inside a subagent; pass through.
if [ -n "$agent_id" ]; then
    exit 0
fi

# ── Determine project dir ────────────────────────────────────────────────────
project_dir="${hook_cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# ── Platform-repo bypass ─────────────────────────────────────────────────────
# This guard exists to prevent cross-app contamination during user-app builds.
# When running in the platform repo itself (cwd is not under a user_apps/ tree),
# there is no isolation requirement — the orchestrator may read anywhere it needs.
# Exit 0 immediately if cwd does not contain /user_apps/ in its path.
case "$project_dir" in
*/user_apps/*) ;; # user-app build context — continue with the guard
*) exit 0 ;;      # platform repo or other non-user-app context — no-op
esac
real_project_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$project_dir")
project_prefix="${real_project_dir%/}/"

# ── Whitelist (resolved once) ────────────────────────────────────────────────
home_dir=$(python3 -c "import os,sys; print(os.path.realpath(os.path.expanduser('~')))")
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
    real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p")
    # Project dir or within it.
    [ "$real" = "$real_project_dir" ] && return 0
    case "$real" in "${project_prefix}"*) return 0 ;; esac
    # Whitelist entries.
    local w wp
    for w in "${whitelist[@]}"; do
        local wreal
        wreal=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$w")
        [ "$real" = "$wreal" ] && return 0
        wp="${wreal%/}/"
        case "$real" in "${wp}"*) return 0 ;; esac
    done
    return 1
}

case "$tool_name" in
Read | Write | Edit | MultiEdit | NotebookEdit)
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
    if [ -z "$file_path" ]; then
        exit 0
    fi
    if is_allowed_path "$file_path"; then
        exit 0
    fi
    printf 'BLOCKED by build-worker-cwd-guard: orchestrator %s on %s is outside the user app dir %s. Subagents may have broader access; the orchestrator does not.\n' \
        "$tool_name" "$file_path" "$project_dir" >&2
    exit 2
    ;;

Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    if [ -z "$command" ]; then
        exit 0
    fi

    # Extract absolute path tokens; skip path-like substrings inside string
    # literals where reasonable. Same heuristic as inspector-bash-guard.sh.
    abs_paths=$(printf '%s' "$command" | grep -oE '/[^ "'"'"'`)]+' || true)

    while IFS= read -r abs_path; do
        [ -z "$abs_path" ] && continue
        # Strip a trailing ; or , or ) the regex may have included.
        abs_path="${abs_path%[);,]}"
        if is_allowed_path "$abs_path"; then
            continue
        fi
        printf 'BLOCKED by build-worker-cwd-guard: orchestrator Bash references %s outside user app dir %s\n' \
            "$abs_path" "$project_dir" >&2
        exit 2
    done <<<"$abs_paths"
    exit 0
    ;;
esac

exit 0
