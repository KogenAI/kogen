#!/usr/bin/env bash
# repo-format.sh — format only git-intent files, not ignored build output.

set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
batch_size="${CODEGEN_FORMAT_BATCH_SIZE:-200}"
exclude_list="${CODEGEN_FORMAT_EXCLUDE:-}"

cd "$repo_root"

is_excluded() {
    local path="$1" item
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        [ "$path" = "$item" ] && return 0
    done <<EOF
$exclude_list
EOF
    return 1
}

has_shell_shebang() {
    local path="$1" first_line
    [ -f "$path" ] || return 1
    IFS= read -r first_line <"$path" || first_line=""
    case "$first_line" in
    '#!'*'/sh' | '#!'*'/bash' | '#!'*'/dash' | '#!'*'/ksh' | '#!'*'/zsh' | '#!'*'env sh' | '#!'*'env bash' | '#!'*'env dash' | '#!'*'env ksh' | '#!'*'env zsh')
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

is_shell_candidate() {
    local path="$1"
    case "$path" in
    *.eex | *.j2)
        return 1
        ;;
    *.bash | *.bats | *.sh | *.zsh)
        return 0
        ;;
    *)
        has_shell_shebang "$path"
        ;;
    esac
}

run_batched() {
    local tool="$1"
    shift
    local -a prefix=("$@")
    local -a batch=()
    local path

    while IFS= read -r -d '' path; do
        batch+=("$path")
        if [ "${#batch[@]}" -ge "$batch_size" ]; then
            "$tool" "${prefix[@]}" -- "${batch[@]}"
            batch=()
        fi
    done

    if [ "${#batch[@]}" -gt 0 ]; then
        "$tool" "${prefix[@]}" -- "${batch[@]}"
    fi
}

tmp_all=$(mktemp)
tmp_shell=$(mktemp)
trap 'rm -f "$tmp_all" "$tmp_shell"' EXIT

while IFS= read -r -d '' path; do
    is_excluded "$path" && continue
    [ -f "$path" ] || continue
    printf '%s\0' "$path" >>"$tmp_all"
    if is_shell_candidate "$path"; then
        printf '%s\0' "$path" >>"$tmp_shell"
    fi
done < <(git ls-files -co --exclude-standard -z)

if [ -s "$tmp_shell" ]; then
    run_batched shfmt -w -i 4 <"$tmp_shell"
fi

if [ -s "$tmp_all" ]; then
    run_batched npx prettier -w --log-level error --ignore-unknown <"$tmp_all"
fi
