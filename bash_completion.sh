#!/bin/bash

# Bash completion for Optimum Codegen (make and ocg commands)
# Source this file or add it to your bash completion directory

_codegen_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD - 1]}" cmd="${COMP_WORDS[0]}"
    COMPREPLY=()

    # Find codegen directory
    local script_dir
    if [[ "$cmd" == "make" ]]; then
        script_dir="$(pwd)"
        [[ ! -f "$script_dir/Makefile" ]] || ! grep -q "Optimum Codegen" "$script_dir/Makefile" 2>/dev/null && return 0
    else
        local cmd_path=$(command -v "$cmd" 2>/dev/null)
        script_dir=$(cd "$(dirname "${cmd_path:-${BASH_SOURCE[0]}}")" && pwd)
        [[ -n "$cmd_path" ]] && script_dir=$(cd "$(dirname "$(readlink -f "$cmd_path" 2>/dev/null || echo "$cmd_path")")" && pwd)
    fi

    # Complete main commands
    if [[ ${COMP_CWORD} == 1 ]]; then
        local opts="bird-eye clean clean-branches clean-servers consolidate-context help ls new plan prepare remove-comments resume rm setup update-context"
        [[ "$cmd" == "make" ]] && opts="$opts install uninstall"
        [[ "$cmd" == "ocg" ]] && opts="$opts uninstall"
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        return 0
    fi

    # Complete arguments
    case "$prev" in
    update-context)
        source "$script_dir/config.sh"
        local repo_root="$TARGET_REPO_PATH"
        [[ -d "$repo_root/codegen/plans" ]] && COMPREPLY=($(compgen -W "$(find "$repo_root/codegen/plans" -name "*.md" -not -name "*.old" -exec basename {} .md \; 2>/dev/null)" -- "$cur"))
        ;;
    rm)
        source "$script_dir/config.sh"
        local repo_root="$TARGET_REPO_PATH"
        [[ -d "$repo_root" ]] && cd "$repo_root" && COMPREPLY=($(compgen -W "$(git worktree list --porcelain 2>/dev/null | grep "^worktree" | cut -d' ' -f2 | xargs -I {} basename {} | grep -v "$(basename "$repo_root")")" -- "$cur"))
        ;;
    new)
        if [[ ${COMP_CWORD} == 2 ]]; then
            source "$script_dir/config.sh"
            local repo_root="$TARGET_REPO_PATH"
            [[ -d "$repo_root/codegen/plans" ]] && COMPREPLY=($(compgen -W "$(find "$repo_root/codegen/plans" -name "*.md" -not -name "*.old" -exec basename {} .md \; 2>/dev/null)" -- "$cur"))
        elif [[ ${COMP_CWORD} == 3 ]]; then
            COMPREPLY=($(compgen -W "sonnet opus --container" -- "$cur"))
        elif [[ ${COMP_CWORD} == 4 ]] && [[ "$cur" == --* ]]; then
            COMPREPLY=($(compgen -W "--container" -- "$cur"))
        fi
        ;;
    resume)
        if [[ ${COMP_CWORD} == 2 ]]; then
            source "$script_dir/config.sh"
            local repo_root="$TARGET_REPO_PATH"
            [[ -d "$repo_root" ]] && cd "$repo_root" && COMPREPLY=($(compgen -W "$(git worktree list --porcelain 2>/dev/null | grep "^worktree" | cut -d' ' -f2 | xargs -I {} basename {} | grep -v "$(basename "$repo_root")")" -- "$cur"))
        elif [[ ${COMP_CWORD} == 3 ]]; then
            COMPREPLY=($(compgen -W "sonnet opus --container" -- "$cur"))
        elif [[ ${COMP_CWORD} == 4 ]] && [[ "$cur" == --* ]]; then
            COMPREPLY=($(compgen -W "--container" -- "$cur"))
        fi
        ;;
    bird-eye | plan)
        if [[ ${COMP_CWORD} == 2 ]]; then
            COMPREPLY=($(compgen -W "" -- "$cur"))
        elif [[ ${COMP_CWORD} == 3 ]]; then
            COMPREPLY=($(compgen -W "sonnet opus" -- "$cur"))
        fi
        ;;
    esac
}

complete -F _codegen_completion make ocg
