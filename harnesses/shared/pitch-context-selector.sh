#!/usr/bin/env bash
# pitch-context-selector.sh -- sole parser of PROJECT_CONTEXT.md
# section "Domain Context Files" for pitch-driven Tier-1 context
# selection. Sourced by claude-shape.sh, claude-experiment.sh,
# pi-shape.sh, pi-experiment.sh. Never executed directly.
#
# Priority: (1) explicitly cited AND keyword-matched, (2) explicitly
# cited only, (3) keyword-matched only. Table order preserved WITHIN
# each tier. First <cap> selected; every remaining eligible row gets
# the cap warning. A SELECTED row whose file is missing is a hard
# error (return 1) -- required context never fails open.
set -uo pipefail

# select_pitch_context <pitch_path> <project_context_md> <repo_root> \
#                      <tier0_loaded> <launcher_label> <cap>
# stdout: newline-delimited repo-relative context paths, in load order.
# stderr: cap warnings; missing-selected-file error.
# return: 0 on success (including empty selection), 1 on missing file.
select_pitch_context() {
    local pitch_path="$1" pc_md="$2" repo_root="$3"
    local tier0_loaded="$4" label="$5" cap="$6"
    local _cited_matched=() _cited_only=() _keyword_only=()
    local _pre _file _domain _ids _rest _ctx_file _ctx_bn
    local _matched _cited _id
    local _id_arr=()

    while IFS='|' read -r _pre _file _domain _ids _rest; do
        case "$_file" in
        *"context/"*.md*) : ;;
        *) continue ;;
        esac
        case "$_file" in
        *"File"* | *"---"*) continue ;;
        esac
        _ctx_file="${_file//\`/}"
        _ctx_file="${_ctx_file## }"
        _ctx_file="${_ctx_file%% }"
        _ctx_bn="${_ctx_file##*/}"
        case "$tier0_loaded" in
        *" ${_ctx_bn}"*) continue ;;
        esac
        # NOTE: no [[ -f ]] pre-filter here -- existence is checked only
        # on SELECTED rows so a missing required file fails loud.
        _matched=0
        IFS=',' read -ra _id_arr <<<"$_ids"
        for _id in "${_id_arr[@]+"${_id_arr[@]}"}"; do
            _id="${_id## }"
            _id="${_id%% }"
            [[ -z "$_id" ]] && continue
            if grep -qiwF "$_id" "$pitch_path" 2>/dev/null; then
                _matched=1
                break
            fi
        done
        _cited=0
        if grep -qF "$_ctx_file" "$pitch_path" 2>/dev/null; then
            _cited=1
        fi
        if [[ $_cited -eq 1 && $_matched -eq 1 ]]; then
            _cited_matched+=("$_ctx_file")
        elif [[ $_cited -eq 1 ]]; then
            _cited_only+=("$_ctx_file")
        elif [[ $_matched -eq 1 ]]; then
            _keyword_only+=("$_ctx_file")
        fi
    done <"$pc_md"

    local _ordered=() _n=0 _f
    _ordered+=("${_cited_matched[@]+"${_cited_matched[@]}"}")
    _ordered+=("${_cited_only[@]+"${_cited_only[@]}"}")
    _ordered+=("${_keyword_only[@]+"${_keyword_only[@]}"}")

    for _f in "${_ordered[@]+"${_ordered[@]}"}"; do
        if [[ $_n -lt $cap ]]; then
            if [[ ! -f "${repo_root}/${_f}" ]]; then
                printf "%s: selected %s is indexed but missing\n" \
                    "$label" "$_f" >&2
                return 1
            fi
            printf "%s\n" "$_f"
            _n=$((_n + 1))
        else
            printf "%s: Tier-1 cap (%s) reached; skipping %s\n" \
                "$label" "$cap" "$_f" >&2
        fi
    done
    return 0
}
