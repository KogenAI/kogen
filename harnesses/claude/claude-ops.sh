#!/usr/bin/env bash
# Built-in subagents denied: Plan, general-purpose, statusline-setup always.
# Explore allowed only under CLAUDE_ROLE=debug/shape/ops.
set -euo pipefail

server="${1:?Usage: claude-ops <server>}"

export CLAUDE_ROLE=ops

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
export CODEGEN_DIR

source "$CODEGEN_DIR/harnesses/claude/load-role.sh"
load_role ops

[[ -n "${CLAUDE_NONINTERACTIVE:-}" ]] && export SSH_TARGET_NON_INTERACTIVE=1

source "$CODEGEN_DIR/harnesses/claude/ssh-target.sh"
resolve_ssh_target "$server" OPS claude-ops

OPS_CONTEXT="Server: ${OPS_ALIAS} (${server_resolved}), Login user: ${OPS_LOGIN_USER}, Operate-as: ${OPS_OPERATE_AS}, Environment: ${ENV_LABEL}"

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

# Non-interactive: pass all non-interactive flags. Interactive: omit (claude handles tty detection).
NON_INTERACTIVE_FLAGS=()
SETTINGS_FLAGS=()
if [[ -n "${CLAUDE_NONINTERACTIVE:-}" ]]; then
    NON_INTERACTIVE_FLAGS+=(
        --print
        --verbose
        --output-format stream-json
        --setting-sources project
        --strict-mcp-config
        --no-session-persistence
        --disable-slash-commands
    )
else
    SETTINGS_FLAGS=(--settings '{"env":{"CLAUDE_AFK_TIMEOUT_MS":"86400000"}}')
fi

OPS_STARTUP_MSG=$'## OPS STARTUP CONTEXT\n'"${OPS_CONTEXT}"$'\n\nConfirm before proceeding.'

CONTEXT_FLAGS=(
    --append-system-prompt "${OPS_STARTUP_MSG}"
)

exec claude \
    "${SETTINGS_FLAGS[@]+"${SETTINGS_FLAGS[@]}"}" \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]}"
