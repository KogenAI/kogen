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
        local opts="doctor format help hook-parity install harness-path-check test uninstall update"
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        return 0
    fi
}

complete -F _codegen_completion make ocg
