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
# For each mode: concat tools_header + each entry in prompt_body[] (ordered list)
# → harnesses/<harness>/<harness>-<mode>-system-prompt.txt (byte-stable write).
# prompt_body is a YAML sequence; each entry is a path relative to CODEGEN_DIR.
# Error (return 1) if tools_header or any prompt_body entry is missing.
manifest_regenerate_prompts() {
    local harness="$1"
    local manifest
    manifest="$(_manifest_path "$harness")"
    local modes
    modes=$(manifest_modes "$harness")

    for mode in $modes; do
        local header dest tmp
        header="$CODEGEN_DIR/$(manifest_mode_get "$harness" "$mode" tools_header)"
        dest="$CODEGEN_DIR/$(manifest_mode_get "$harness" "$mode" system_prompt_file)"

        if [ ! -f "$header" ]; then
            echo "manifest-lib: ERROR — tools-header not found: $header" >&2
            return 1
        fi

        # Collect prompt_body entries (YAML sequence).
        local body_count body_entries
        body_count=$(yq -r ".modes.$mode.prompt_body | length" "$manifest")
        body_entries=()
        local j=0
        while [ "$j" -lt "$body_count" ]; do
            local entry
            entry="$CODEGEN_DIR/$(yq -r ".modes.$mode.prompt_body[$j]" "$manifest")"
            if [ ! -f "$entry" ]; then
                echo "manifest-lib: ERROR — prompt_body[$j] not found: $entry" >&2
                return 1
            fi
            body_entries+=("$entry")
            j=$((j + 1))
        done

        tmp=$(mktemp)
        # Cat header first, then each body entry in order (skip empty entries).
        local inputs=("$header")
        for entry in "${body_entries[@]+"${body_entries[@]}"}"; do
            if [ -s "$entry" ]; then
                inputs+=("$entry")
            fi
        done
        cat "${inputs[@]}" >"$tmp"

        # Byte-stable write: only overwrite if content changed.
        #
        # The overwrite is a rename, not a copy, so a concurrent reader sees
        # either the whole old file or the whole new one — never a half-written
        # prefix. `cp` here was a torn-read waiting to happen: these files are
        # read by prompt-content-parity and by every `claude-*.sh` launcher,
        # and a 137 KB `cp` is not close to atomic. The staging file is created
        # in the DESTINATION directory (not $TMPDIR) because rename(2) is only
        # atomic within one filesystem, and on macOS $TMPDIR is routinely a
        # different volume than the repo.
        if [ ! -f "$dest" ] || ! cmp -s "$tmp" "$dest"; then
            local stage
            stage=$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")
            cat "$tmp" >"$stage"
            chmod 600 "$stage"
            mv -f "$stage" "$dest"
            echo "   manifest-lib: regenerated $harness/$mode prompt → $(basename "$dest")"
        fi
        rm -f "$tmp"
    done
}
