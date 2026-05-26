#!/usr/bin/env bash
# templates/generator/manifest-lib.sh — sourced helper for manifest-driven generate/install.
#
# Usage: source "$CODEGEN_DIR/templates/generator/manifest-lib.sh"
#
# Provides:
#   manifest_get <harness> <yq-path>            — read a scalar from harness manifest
#   manifest_launchers <harness>                — print "src dest_name" pairs, one per line
#   manifest_completions <harness>              — print completion filenames, one per line
#   manifest_modes <harness>                    — print mode names, one per line
#   manifest_mode_get <harness> <mode> <key>    — read a scalar from modes.<mode>.<key>
#   manifest_regenerate_prompts <harness>       — concat tools-header + shared body → *-system-prompt.txt
#
# Requires: yq on PATH, CODEGEN_DIR set.

set -u

_manifest_path() {
    local harness="$1"
    echo "${CODEGEN_DIR:?CODEGEN_DIR not set}/harnesses/$harness/manifest.yaml"
}

# manifest_get <harness> <yq-path>
manifest_get() {
    local harness="$1"
    local path="$2"
    yq -r "$path" "$(_manifest_path "$harness")"
}

# manifest_launchers <harness>
# Prints one line per launcher: "<src> <name>" (both relative to CODEGEN_DIR)
manifest_launchers() {
    local harness="$1"
    local manifest
    manifest="$(_manifest_path "$harness")"
    local count
    count=$(yq -r '.launchers | length' "$manifest")
    local i=0
    while [ "$i" -lt "$count" ]; do
        local src name
        src=$(yq -r ".launchers[$i].src" "$manifest")
        name=$(yq -r ".launchers[$i].name" "$manifest")
        echo "$src $name"
        i=$((i + 1))
    done
}

# manifest_completions <harness>
# Prints one line per completion filename (e.g. _claude-build)
manifest_completions() {
    local harness="$1"
    local manifest
    manifest="$(_manifest_path "$harness")"
    local count
    count=$(yq -r '.completions | length' "$manifest")
    local i=0
    while [ "$i" -lt "$count" ]; do
        yq -r ".completions[$i]" "$manifest"
        i=$((i + 1))
    done
}

# manifest_modes <harness>
# Prints mode names one per line (build debug shape refactor)
manifest_modes() {
    local harness="$1"
    yq -r '.modes | keys | .[]' "$(_manifest_path "$harness")"
}

# manifest_mode_get <harness> <mode> <key>
manifest_mode_get() {
    local harness="$1"
    local mode="$2"
    local key="$3"
    yq -r ".modes.$mode.$key" "$(_manifest_path "$harness")"
}

# manifest_regenerate_prompts <harness>
# For each mode: concat tools-header/<mode>.txt + shared/prompt-bodies/<mode>.txt
# → harnesses/<harness>/<harness>-<mode>-system-prompt.txt (byte-stable write).
manifest_regenerate_prompts() {
    local harness="$1"
    local manifest
    manifest="$(_manifest_path "$harness")"
    local modes
    modes=$(manifest_modes "$harness")

    for mode in $modes; do
        local header body dest tmp
        header="$CODEGEN_DIR/$(manifest_mode_get "$harness" "$mode" tools_header)"
        body="$CODEGEN_DIR/$(manifest_mode_get "$harness" "$mode" prompt_body)"
        dest="$CODEGEN_DIR/$(manifest_mode_get "$harness" "$mode" system_prompt_file)"

        if [ ! -f "$header" ]; then
            echo "manifest-lib: ERROR — tools-header not found: $header" >&2
            return 1
        fi

        tmp=$(mktemp)
        if [ -f "$body" ] && [ -s "$body" ]; then
            cat "$header" "$body" >"$tmp"
        else
            cat "$header" >"$tmp"
        fi

        # Byte-stable write: only overwrite if content changed.
        if [ ! -f "$dest" ] || ! cmp -s "$tmp" "$dest"; then
            cp "$tmp" "$dest"
            echo "   manifest-lib: regenerated $harness/$mode prompt → $(basename "$dest")"
        fi
        rm -f "$tmp"
    done
}
