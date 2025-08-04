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
        local opts="ai-config bird-eye clean clean-branches clean-servers consolidate-context help ls new plan prepare remove-comments resources resume rm setup update-context"
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
        if [[ -d "$repo_root/codegen/plans" ]]; then
            local plans=""
            # Get directories (modular plans)
            plans="$plans $(find "$repo_root/codegen/plans" -maxdepth 1 -type d -not -name "plans" -exec basename {} \; 2>/dev/null)"
            # Get .md files (single file plans)
            plans="$plans $(find "$repo_root/codegen/plans" -maxdepth 1 -name "*.md" -not -name "*.old" -exec basename {} .md \; 2>/dev/null)"
            COMPREPLY=($(compgen -W "$plans" -- "$cur"))
        fi
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
            if [[ -d "$repo_root/codegen/plans" ]]; then
                local plans=""
                # Get directories (modular plans)
                plans="$plans $(find "$repo_root/codegen/plans" -maxdepth 1 -type d -not -name "plans" -exec basename {} \; 2>/dev/null)"
                # Get .md files (single file plans)
                plans="$plans $(find "$repo_root/codegen/plans" -maxdepth 1 -name "*.md" -not -name "*.old" -exec basename {} .md \; 2>/dev/null)"
                COMPREPLY=($(compgen -W "$plans" -- "$cur"))
            fi
        elif [[ "$cur" == --* ]]; then
            COMPREPLY=($(compgen -W "--model --assistant --container" -- "$cur"))
        elif [[ "$prev" == "--model" || "$prev" == "-m" ]]; then
            COMPREPLY=($(compgen -W "sonnet opus" -- "$cur"))
        elif [[ "$prev" == "--assistant" || "$prev" == "-a" || "$prev" == "--ai" ]]; then
            COMPREPLY=($(compgen -W "claude opencode" -- "$cur"))
        fi
        ;;
    resume)
        if [[ ${COMP_CWORD} == 2 ]]; then
            source "$script_dir/config.sh"
            local repo_root="$TARGET_REPO_PATH"
            [[ -d "$repo_root" ]] && cd "$repo_root" && COMPREPLY=($(compgen -W "$(git worktree list --porcelain 2>/dev/null | grep "^worktree" | cut -d' ' -f2 | xargs -I {} basename {} | grep -v "$(basename "$repo_root")")" -- "$cur"))
        elif [[ "$cur" == --* ]]; then
            COMPREPLY=($(compgen -W "--model --assistant --container" -- "$cur"))
        elif [[ "$prev" == "--model" || "$prev" == "-m" ]]; then
            COMPREPLY=($(compgen -W "sonnet opus" -- "$cur"))
        elif [[ "$prev" == "--assistant" || "$prev" == "-a" || "$prev" == "--ai" ]]; then
            COMPREPLY=($(compgen -W "claude opencode" -- "$cur"))
        fi
        ;;
    bird-eye | plan)
        if [[ ${COMP_CWORD} == 2 ]]; then
            COMPREPLY=($(compgen -W "" -- "$cur"))
        elif [[ ${COMP_CWORD} == 3 ]]; then
            COMPREPLY=($(compgen -W "sonnet opus" -- "$cur"))
        fi
        ;;
    ai-config)
        if [[ ${COMP_CWORD} == 2 ]]; then
            COMPREPLY=($(compgen -W "set get status" -- "$cur"))
        elif [[ ${COMP_CWORD} == 3 && "$prev" == "set" ]]; then
            COMPREPLY=($(compgen -W "default" -- "$cur"))
        elif [[ ${COMP_CWORD} == 4 && "${COMP_WORDS[2]}" == "set" && "${COMP_WORDS[3]}" == "default" ]]; then
            COMPREPLY=($(compgen -W "claude opencode" -- "$cur"))
        elif [[ ${COMP_CWORD} == 3 && "$prev" == "get" ]]; then
            COMPREPLY=($(compgen -W "default" -- "$cur"))
        fi
        ;;
    resources)
        if [[ ${COMP_CWORD} == 2 ]]; then
            COMPREPLY=($(compgen -W "--cleanup-orphaned --orphaned" -- "$cur"))
        fi
        ;;
    esac
}

complete -F _codegen_completion make ocg
