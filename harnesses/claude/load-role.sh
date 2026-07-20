#!/usr/bin/env bash
set -u

# shellcheck source=harnesses/shared/mode-context.sh
source "${CODEGEN_DIR:?CODEGEN_DIR not set}/harnesses/shared/mode-context.sh"

# load_role <role> — loads role config from config.yaml into env vars
# Sets: ROLE_MODEL, ROLE_EFFORT, ROLE_THINKING_TOKENS, ROLE_DISALLOWED, ROLE_ALLOWED,
#       ROLE_SYSTEM_PROMPT, ROLE_OUTPUT_FORMAT, ROLE_APPEND_PROJECT_CONTEXT, ROLE_TEMPLATE,
#       ROLE_CONTEXT_FILES
load_role() {
    local role="$1"
    local cfg="${CODEGEN_DIR:?CODEGEN_DIR not set}/templates/generator/config.yaml"

    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq not found. Install via: brew install yq (macOS) or apt-get install yq (Linux)" >&2
        exit 1
    fi

    ROLE_MODEL=$(yq -r ".roles.$role.model // \"\"" "$cfg")
    ROLE_EFFORT=$(yq -r ".roles.$role.effort // \"\"" "$cfg")
    if [ -z "$ROLE_MODEL" ] || [ "$ROLE_MODEL" = "null" ]; then
        echo "ERROR: roles.$role.model missing/empty in $cfg" >&2
        exit 1
    fi
    if [ -z "$ROLE_EFFORT" ] || [ "$ROLE_EFFORT" = "null" ]; then
        echo "ERROR: roles.$role.effort missing/empty in $cfg" >&2
        exit 1
    fi

    local thinking_raw
    thinking_raw=$(yq -r ".roles.$role.thinking_tokens // \"\"" "$cfg")
    if [ -n "$thinking_raw" ] && [ "$thinking_raw" != "null" ]; then
        if ! [[ "$thinking_raw" =~ ^[0-9]+$ ]] || [ "$thinking_raw" -le 0 ]; then
            echo "ERROR: roles.$role.thinking_tokens missing/invalid in $cfg" >&2
            exit 1
        fi
        ROLE_THINKING_TOKENS="$thinking_raw"
    else
        ROLE_THINKING_TOKENS=""
    fi

    ROLE_DISALLOWED=$(yq -r "(.roles.$role.disallowed_tools // []) | join(\",\")" "$cfg")
    ROLE_ALLOWED=$(yq -r "(.roles.$role.allowed_tools // []) | join(\",\")" "$cfg")
    ROLE_TOOLS=$(yq -r "(.roles.$role.tools // []) | join(\",\")" "$cfg")
    ROLE_OUTPUT_FORMAT=$(yq -r ".roles.$role.output_format // \"text\"" "$cfg")
    ROLE_APPEND_PROJECT_CONTEXT=$(yq -r ".roles.$role.append_project_context // false" "$cfg")
    ROLE_TEMPLATE=$(yq -r ".roles.$role.system_prompt_template // false" "$cfg")

    local sp_file=$(yq -r ".roles.$role.system_prompt_file // \"\"" "$cfg")
    if [ -n "$sp_file" ] && [ "$sp_file" != "null" ]; then
        ROLE_SYSTEM_PROMPT=$(cat "$CODEGEN_DIR/$sp_file")
    else
        ROLE_SYSTEM_PROMPT=$(yq -r ".roles.$role.system_prompt" "$cfg")
    fi

    resolve_mode_context "$role"
}
