#!/bin/bash
# inspector-bash-guard.sh — PreToolUse hook for Inspector
#
# Blocks Bash commands that mutate the filesystem or database, and commands
# that reference absolute paths outside $CLAUDE_PROJECT_DIR.
#
# Mutating-command patterns rejected:
#   echo ... >   (redirect-overwrite)
#   cat <<       (heredoc)
#   tee
#   >>  (append redirect)
#   sed -i (in-place edit)
#   mv / cp / rm / mkdir / touch / chmod / chown
#   git commit / git add / git push / git reset / git rebase
#   SQL mutations: INSERT, UPDATE, DELETE, DROP, TRUNCATE
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

# Only gate Bash calls.
if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# ── Mutating-command pattern blocks ──────────────────────────────────────────

# Append redirect >>
if printf '%s' "$command" | grep -qE '>>'; then
    printf 'BLOCKED by inspector-bash-guard: append-redirect (>>) is forbidden for Inspector\n' >&2
    exit 2
fi

# Redirect-overwrite: bare > redirect (but not >>)
if printf '%s' "$command" | grep -qE '[^>]>[^>]|^>[^>]'; then
    printf 'BLOCKED by inspector-bash-guard: redirect-write (>) is forbidden for Inspector\n' >&2
    exit 2
fi

# heredoc: cat <<
if printf '%s' "$command" | grep -qE 'cat[[:space:]]+<<'; then
    printf 'BLOCKED by inspector-bash-guard: heredoc (cat <<) is forbidden for Inspector\n' >&2
    exit 2
fi

# tee
if printf '%s' "$command" | grep -qE '\btee\b'; then
    printf 'BLOCKED by inspector-bash-guard: tee is forbidden for Inspector\n' >&2
    exit 2
fi

# sed -i (in-place edit)
if printf '%s' "$command" | grep -qE '\bsed[[:space:]]+(-[^ ]*i|--in-place)'; then
    printf 'BLOCKED by inspector-bash-guard: sed -i is forbidden for Inspector\n' >&2
    exit 2
fi

# Mutating file-system commands: mv, cp, rm, mkdir, touch, chmod, chown
if printf '%s' "$command" | grep -qE '\b(mv|cp|rm|mkdir|touch|chmod|chown)\b'; then
    printf 'BLOCKED by inspector-bash-guard: filesystem-mutation command is forbidden for Inspector\n' >&2
    exit 2
fi

# Git mutation commands
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+(commit|add|push|reset|rebase)\b'; then
    printf 'BLOCKED by inspector-bash-guard: git write command is forbidden for Inspector\n' >&2
    exit 2
fi

# SQL mutations (case-insensitive)
if printf '%s' "$command" | grep -qiE '\b(INSERT|UPDATE|DELETE|DROP|TRUNCATE)\b'; then
    printf 'BLOCKED by inspector-bash-guard: SQL mutation is forbidden for Inspector\n' >&2
    exit 2
fi

# ── Absolute path outside working dir ────────────────────────────────────────

# Extract any absolute paths from the command and check them against the project dir.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
real_project_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$project_dir")
project_prefix="${real_project_dir%/}/"

# Find absolute paths in the command (sequences starting with /).
# Note: BSD grep (macOS) does not treat \t as tab in ERE character classes —
# use a simple [^ "'`]+ pattern to avoid false splits on path characters.
abs_paths=$(printf '%s' "$command" | grep -oE '/[^ "'"'"'`]+' || true)

while IFS= read -r abs_path; do
    [ -z "$abs_path" ] && continue

    real_abs=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$abs_path")

    # Allow if path is the project dir or within it.
    if [ "$real_abs" = "$real_project_dir" ]; then
        continue
    fi

    case "$real_abs" in
    "${project_prefix}"*)
        continue
        ;;
    esac

    # /dev/null and /tmp are always allowed for read-only operations.
    case "$real_abs" in
    /dev/null | /private/tmp/* | /tmp/*)
        continue
        ;;
    esac

    printf 'BLOCKED by inspector-bash-guard: absolute path %s is outside working dir %s\n' \
        "$abs_path" "$project_dir" >&2
    exit 2
done <<<"$abs_paths"

exit 0
