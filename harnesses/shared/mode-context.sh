#!/usr/bin/env bash
set -uo pipefail

# resolve_mode_context <mode> — resolves declared context files for a launcher
# mode from config.yaml roles.<mode>.context_files, into ROLE_CONTEXT_FILES
# (newline-separated, repo-relative paths). Fail-loud: a declared path that
# does not exist under $CODEGEN_DIR is a hard exit 1 naming the mode and path.
# Sole reader of roles.<mode>.context_files — consumed by load-role.sh
# (claude leg) and pi-babysit.sh/pi-ops.sh/pi-debug.sh (pi leg) directly.
resolve_mode_context() {
    local mode="$1"
    local cfg="${CODEGEN_DIR:?CODEGEN_DIR not set}/templates/generator/config.yaml"

    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq not found. Install via: brew install yq (macOS) or apt-get install yq (Linux)" >&2
        exit 1
    fi

    local files
    files=$(yq -r ".roles.$mode.context_files // [] | .[]" "$cfg")

    local resolved=""
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -f "$CODEGEN_DIR/$f" ]; then
            echo "resolve_mode_context: roles.$mode.context_files declares $f, not found at $CODEGEN_DIR/$f" >&2
            exit 1
        fi
        if [ -z "$resolved" ]; then
            resolved="$f"
        else
            resolved="${resolved}"$'\n'"$f"
        fi
    done <<<"$files"

    ROLE_CONTEXT_FILES="$resolved"
    export ROLE_CONTEXT_FILES
}
