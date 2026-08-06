#!/usr/bin/env bash
# shell-syntax-check.sh — every tracked shell script must parse.
#
# Why this exists as its OWN gate stage rather than as a side effect of the
# test that happens to run the script:
#
# A shell script with a syntax error does not fail once. `codegen-build` with
# an unbalanced `if` produced `./codegen-build: line 302: syntax error:
# unexpected end of file` and THIRTEEN red assertions in codegen-build_test.sh
# — every one of them a symptom, none of them the cause. The developer then
# spends the cycle reading thirteen unrelated-looking failures to rediscover
# one missing `fi`. Worse, the file the gate cannot parse is very often the
# file the developer is mid-edit on, so the gate reports the developer's own
# subject as broken in thirteen places.
#
# `bash -n` costs milliseconds and answers the question exactly once. Running
# it as a first-class stage means a parse error is reported as a parse error,
# by name, next to the parser's own line number.
#
# Discovery: tracked files with a .sh/.bash extension, PLUS tracked
# extensionless executables whose shebang names a shell (codegen-build,
# codegen-call, codegen-drain, codegen-log, ...) — the extensionless launchers
# are exactly where the observed failure lived.
#
# zsh scripts are checked with `zsh -n`: `bash -n` misparses zsh completion
# syntax (context/bash-patterns.md). If zsh is not installed they are skipped
# with a named notice rather than silently passed.
#
# Usage: shell-syntax-check.sh [repo_root]
# Exit 0: every discovered script parses. Exit 1: one or more do not.
set -uo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root" || exit 1

checked=0
skipped=""
failures=""

while IFS= read -r f; do
    [ -f "$f" ] || continue

    # Un-rendered templates carry a shell shebang but are not shell until a
    # renderer substitutes their placeholders (`<%= dev_port %>`), so `bash -n`
    # on the SOURCE is a guaranteed false positive. Their rendered output is
    # exercised by the scaffold suites.
    case "$f" in
    *.eex | *.j2 | *.tmpl | *.template) continue ;;
    esac

    shebang=$(head -1 "$f" 2>/dev/null)
    case "$f" in
    *.sh | *.bash) is_shell=1 ;;
    *)
        case "$shebang" in
        '#!'*sh*) is_shell=1 ;;
        *) is_shell=0 ;;
        esac
        ;;
    esac
    [ "$is_shell" = "1" ] || continue

    case "$shebang" in
    *zsh*)
        if command -v zsh >/dev/null 2>&1; then
            if ! out=$(zsh -n "$f" 2>&1); then
                failures="${failures}${failures:+
}shell-syntax: $f does not parse (zsh -n):
${out}"
            fi
            checked=$((checked + 1))
        else
            skipped="${skipped}${skipped:+, }$f"
        fi
        ;;
    *)
        if ! out=$(bash -n "$f" 2>&1); then
            failures="${failures}${failures:+
}shell-syntax: $f does not parse (bash -n):
${out}"
        fi
        checked=$((checked + 1))
        ;;
    esac
done < <(git ls-files -z 2>/dev/null | tr '\0' '\n' | grep -vE '^(node_modules|deps)/')

if [ -n "$skipped" ]; then
    printf 'shell-syntax: zsh not installed — skipped: %s\n' "$skipped"
fi

if [ -n "$failures" ]; then
    printf '%s\n' "$failures"
    exit 1
fi

if [ "$checked" -eq 0 ]; then
    printf 'shell-syntax: discovered zero shell scripts — the scan matched nothing, which cannot be right\n' >&2
    exit 1
fi

[ -n "${VERBOSE:-}" ] && printf 'shell-syntax: OK — %s script(s) parse\n' "$checked"
exit 0
