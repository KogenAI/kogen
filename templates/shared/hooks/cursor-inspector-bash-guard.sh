#!/bin/bash
# cursor-inspector-bash-guard.sh — beforeShellExecution hook for Cursor Inspector
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: beforeShellExecution
# surface: per_call_inspector
# signal: none
# role: cursor-inspector
#
# Blocks shell commands that mutate the filesystem or database, and commands
# that reference absolute paths outside the project directory.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Cursor uses .command at root level, not .tool_input.command. parse_input
# already populates COMMAND from .tool_input.command; fall back to root.
if [ -z "$COMMAND" ]; then
    COMMAND=$(printf '%s' "$RAW_INPUT" | jq -r '.command // ""')
fi

# Extract project cwd from stdin JSON; CWD already populated by parse_input.
project_dir="${CWD:-$PWD}"

# Strip stderr-redirect tokens before the redirect-overwrite check.
redirect_check=$(printf '%s' "$COMMAND" | sed -e 's/2>&1//g' -e 's|2>/dev/null||g')

# ── Path traversal block ─────────────────────────────────────────────────────

# Deny any command containing relative path traversal (../).
if printf '%s' "$COMMAND" | grep -qE '\.\./'; then
    deny "BLOCKED by cursor-inspector-bash-guard: relative path traversal (..) forbidden — use absolute paths only"
    exit 0
fi

# ── Mutating-command pattern blocks ──────────────────────────────────────────

# Append redirect >>
if printf '%s' "$redirect_check" | grep -qE '>>'; then
    deny "BLOCKED by cursor-inspector-bash-guard: append-redirect (>>) is forbidden for Inspector"
    exit 0
fi

# Redirect-overwrite: bare > redirect (but not >>)
if printf '%s' "$redirect_check" | grep -qE '[^>]>[^>]|^>[^>]'; then
    deny "BLOCKED by cursor-inspector-bash-guard: redirect-write (>) is forbidden for Inspector"
    exit 0
fi

# heredoc: cat <<
if printf '%s' "$COMMAND" | grep -qE 'cat[[:space:]]+<<'; then
    deny "BLOCKED by cursor-inspector-bash-guard: heredoc (cat <<) is forbidden for Inspector"
    exit 0
fi

# tee
if printf '%s' "$COMMAND" | grep -qE '\btee\b'; then
    deny "BLOCKED by cursor-inspector-bash-guard: tee is forbidden for Inspector"
    exit 0
fi

# sed -i (in-place edit)
if printf '%s' "$COMMAND" | grep -qE '\bsed[[:space:]]+(-[^ ]*i|--in-place)'; then
    deny "BLOCKED by cursor-inspector-bash-guard: sed -i is forbidden for Inspector"
    exit 0
fi

# Mutating file-system commands: mv, cp, rm, mkdir, touch, chmod, chown
if printf '%s' "$COMMAND" | grep -qE '\b(mv|cp|rm|mkdir|touch|chmod|chown)\b'; then
    deny "BLOCKED by cursor-inspector-bash-guard: filesystem-mutation command is forbidden for Inspector"
    exit 0
fi

# Git mutation commands
if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+(commit|add|push|reset|rebase)\b'; then
    deny "BLOCKED by cursor-inspector-bash-guard: git write command is forbidden for Inspector"
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
            deny "BLOCKED by cursor-inspector-bash-guard: SQL mutation is forbidden for Inspector"
            exit 0
        fi
    fi
    ;;
esac

# ── Project-dir containment check ────────────────────────────────────────────

real_project_dir=$(hooks_realpath "$project_dir")
project_prefix="${real_project_dir%/}/"

abs_paths=$(printf '%s' "$COMMAND" | grep -oE '/[^ "'"'"'`]+' || true)

while IFS= read -r abs_path; do
    [ -z "$abs_path" ] && continue

    real_abs=$(hooks_realpath "$abs_path")

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

    # Block read-only commands with absolute paths outside project dir.
    if printf '%s' "$COMMAND" | grep -qE '\b(cat|head|tail|less|more|awk)\b'; then
        deny "BLOCKED by cursor-inspector-bash-guard: read of path $abs_path is outside working dir $project_dir"
        exit 0
    fi

    deny "BLOCKED by cursor-inspector-bash-guard: absolute path $abs_path is outside working dir $project_dir"
    exit 0
done <<<"$abs_paths"

exit 0
