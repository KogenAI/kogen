#!/bin/bash
# codex-inspector-bash-guard.sh — PreToolUse hook for Codex Inspector
#
# Blocks shell/local_shell tool calls that mutate the filesystem or database,
# OR that read files outside $CODEX_PROJECT_DIR.
#
# Codex has no separate Read tool — bash IS the read surface — so this guard
# merges write-guard + read-guard duties.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Only gate shell/local_shell calls.
if ! printf '%s' "$TOOL_NAME" | grep -qE '^shell$|^local_shell$'; then
    exit 0
fi

# Strip stderr-redirect tokens before the redirect-overwrite check.
redirect_check=$(printf '%s' "$COMMAND" | sed -e 's/2>&1//g' -e 's|2>/dev/null||g')

# ── Path traversal block ─────────────────────────────────────────────────────

# Deny any command containing relative path traversal (../).
if printf '%s' "$COMMAND" | grep -qE '\.\./' ; then
    deny "BLOCKED by codex-inspector-bash-guard: relative path traversal (..) forbidden — use absolute paths only"
    exit 0
fi

# ── Mutating-command pattern blocks ──────────────────────────────────────────

# Append redirect >>
if printf '%s' "$redirect_check" | grep -qE '>>'; then
    deny "BLOCKED by codex-inspector-bash-guard: append-redirect (>>) is forbidden for Inspector"
    exit 0
fi

# Redirect-overwrite: bare > redirect (but not >>)
if printf '%s' "$redirect_check" | grep -qE '[^>]>[^>]|^>[^>]'; then
    deny "BLOCKED by codex-inspector-bash-guard: redirect-write (>) is forbidden for Inspector"
    exit 0
fi

# heredoc: cat <<
if printf '%s' "$COMMAND" | grep -qE 'cat[[:space:]]+<<'; then
    deny "BLOCKED by codex-inspector-bash-guard: heredoc (cat <<) is forbidden for Inspector"
    exit 0
fi

# tee
if printf '%s' "$COMMAND" | grep -qE '\btee\b'; then
    deny "BLOCKED by codex-inspector-bash-guard: tee is forbidden for Inspector"
    exit 0
fi

# sed -i (in-place edit)
if printf '%s' "$COMMAND" | grep -qE '\bsed[[:space:]]+(-[^ ]*i|--in-place)'; then
    deny "BLOCKED by codex-inspector-bash-guard: sed -i is forbidden for Inspector"
    exit 0
fi

# Mutating file-system commands: mv, cp, rm, mkdir, touch, chmod, chown
if printf '%s' "$COMMAND" | grep -qE '\b(mv|cp|rm|mkdir|touch|chmod|chown)\b'; then
    deny "BLOCKED by codex-inspector-bash-guard: filesystem-mutation command is forbidden for Inspector"
    exit 0
fi

# Git mutation commands
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+(commit|add|push|reset|rebase)\b'; then
    deny "BLOCKED by codex-inspector-bash-guard: git write command is forbidden for Inspector"
    exit 0
fi

# SQL mutations — only fire when the command actually executes SQL.
leading_verb=$(printf '%s' "$COMMAND" | awk '{print $1}')
case "$leading_verb" in
grep | sed | awk | find | git)
    # Inspection commands — keywords like DELETE/DROP are legitimate search terms.
    ;;
*)
    if printf '%s' "$COMMAND" | grep -qE '\b(psql|Repo\.query|Repo\.execute|Repo\.insert_all|Repo\.update_all|Repo\.delete_all)\b'; then
        if printf '%s' "$COMMAND" | grep -qiE '\b(INSERT|UPDATE|DELETE|DROP|TRUNCATE)\b'; then
            deny "BLOCKED by codex-inspector-bash-guard: SQL mutation is forbidden for Inspector"
            exit 0
        fi
    fi
    ;;
esac

# ── Project-dir containment check (read-block) ───────────────────────────────

project_dir="${CODEX_PROJECT_DIR:-$PWD}"
real_project_dir=$(hooks_realpath "$project_dir")
project_prefix="${real_project_dir%/}/"

# Find absolute paths in the command.
abs_paths=$(printf '%s' "$COMMAND" | grep -oE '/[^ "'"'"'`]+' || true)

while IFS= read -r abs_path; do
    [ -z "$abs_path" ] && continue

    real_abs=$(hooks_realpath "$abs_path")

    # Allow if path is the project dir or within it.
    if [ "$real_abs" = "$real_project_dir" ]; then
        continue
    fi

    case "$real_abs" in
    "${project_prefix}"*)
        continue
        ;;
    esac

    # /dev/null and /tmp are always allowed.
    case "$real_abs" in
    /dev/null | /private/tmp/* | /tmp/*)
        continue
        ;;
    esac

    # Check if this absolute path is being used as a read-target by a read-only command.
    if printf '%s' "$COMMAND" | grep -qE '\b(cat|head|tail|less|more|awk)\b'; then
        deny "BLOCKED by codex-inspector-bash-guard: read of path $abs_path is outside working dir $project_dir"
        exit 0
    fi

    deny "BLOCKED by codex-inspector-bash-guard: absolute path $abs_path is outside working dir $project_dir"
    exit 0
done <<<"$abs_paths"

exit 0
