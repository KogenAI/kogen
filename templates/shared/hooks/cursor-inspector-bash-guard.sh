#!/bin/bash
# cursor-inspector-bash-guard.sh — beforeShellExecution hook for Cursor Inspector
#
# Blocks shell commands that mutate the filesystem or database, and commands
# that reference absolute paths outside the project directory.
#
# Cursor fires beforeShellExecution hooks only for shell execution — no
# tool_name gating needed. Project directory is read from JSON-on-stdin:
#   .cwd // .tool_input.cwd  (empty → falls back to $PWD)
#
# Mutating-command patterns rejected (same as inspector-bash-guard.sh):
#   echo ... >   (redirect-overwrite)
#   cat <<       (heredoc)
#   tee
#   >>           (append redirect)
#   sed -i       (in-place edit)
#   mv / cp / rm / mkdir / touch / chmod / chown
#   git commit / git add / git push / git reset / git rebase
#   SQL mutations: INSERT, UPDATE, DELETE, DROP, TRUNCATE
#
# Read-block patterns (bare read tools with absolute path outside project dir):
#   cat / head / tail / less / more / awk with an absolute path outside cwd.
#
# Exit codes:
#   0 — allow the command
#   2 — block the command (Cursor beforeShellExecution convention)

set -euo pipefail

input=$(cat)

command=$(printf '%s' "$input" | jq -r '.command // .tool_input.command // ""')

# Extract project cwd from stdin JSON; fall back to $PWD.
cwd=$(printf '%s' "$input" | jq -r '.cwd // .tool_input.cwd // ""')
project_dir="${cwd:-$PWD}"

# Strip stderr-redirect tokens before the redirect-overwrite check.
redirect_check=$(printf '%s' "$command" | sed -e 's/2>&1//g' -e 's|2>/dev/null||g')

# ── Mutating-command pattern blocks ──────────────────────────────────────────

# Append redirect >>
if printf '%s' "$redirect_check" | grep -qE '>>'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: append-redirect (>>) is forbidden for Inspector\n' >&2
    exit 2
fi

# Redirect-overwrite: bare > redirect (but not >>)
if printf '%s' "$redirect_check" | grep -qE '[^>]>[^>]|^>[^>]'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: redirect-write (>) is forbidden for Inspector\n' >&2
    exit 2
fi

# heredoc: cat <<
if printf '%s' "$command" | grep -qE 'cat[[:space:]]+<<'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: heredoc (cat <<) is forbidden for Inspector\n' >&2
    exit 2
fi

# tee
if printf '%s' "$command" | grep -qE '\btee\b'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: tee is forbidden for Inspector\n' >&2
    exit 2
fi

# sed -i (in-place edit)
if printf '%s' "$command" | grep -qE '\bsed[[:space:]]+(-[^ ]*i|--in-place)'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: sed -i is forbidden for Inspector\n' >&2
    exit 2
fi

# Mutating file-system commands: mv, cp, rm, mkdir, touch, chmod, chown
if printf '%s' "$command" | grep -qE '\b(mv|cp|rm|mkdir|touch|chmod|chown)\b'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: filesystem-mutation command is forbidden for Inspector\n' >&2
    exit 2
fi

# Git mutation commands
if printf '%s' "$command" | grep -qE '\bgit[[:space:]]+(commit|add|push|reset|rebase)\b'; then
    printf 'BLOCKED by cursor-inspector-bash-guard: git write command is forbidden for Inspector\n' >&2
    exit 2
fi

# SQL mutations — only fire when the command actually executes SQL.
leading_verb=$(printf '%s' "$command" | awk '{print $1}')
case "$leading_verb" in
grep | sed | awk | find | git)
    # Inspection commands — keywords like DELETE/DROP are legitimate search terms.
    ;;
*)
    if printf '%s' "$command" | grep -qE '\b(psql|Repo\.query|Repo\.execute|Repo\.insert_all|Repo\.update_all|Repo\.delete_all)\b'; then
        if printf '%s' "$command" | grep -qiE '\b(INSERT|UPDATE|DELETE|DROP|TRUNCATE)\b'; then
            printf 'BLOCKED by cursor-inspector-bash-guard: SQL mutation is forbidden for Inspector\n' >&2
            exit 2
        fi
    fi
    ;;
esac

# ── Project-dir containment check ────────────────────────────────────────────

real_project_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$project_dir")
project_prefix="${real_project_dir%/}/"

abs_paths=$(printf '%s' "$command" | grep -oE '/[^ "'"'"'`]+' || true)

while IFS= read -r abs_path; do
    [ -z "$abs_path" ] && continue

    real_abs=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$abs_path")

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
    if printf '%s' "$command" | grep -qE '\b(cat|head|tail|less|more|awk)\b'; then
        printf 'BLOCKED by cursor-inspector-bash-guard: read of path %s is outside working dir %s\n' \
            "$abs_path" "$project_dir" >&2
        exit 2
    fi

    printf 'BLOCKED by cursor-inspector-bash-guard: absolute path %s is outside working dir %s\n' \
        "$abs_path" "$project_dir" >&2
    exit 2
done <<<"$abs_paths"

exit 0
