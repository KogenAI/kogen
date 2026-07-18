#!/usr/bin/env bash
# Built-in subagents denied: Plan, general-purpose, statusline-setup always.
# Explore allowed only under CLAUDE_ROLE=debug/shape/ops.
set -euo pipefail

server="${1:?Usage: claude-debug <server> [claude args...]}"
shift

export CLAUDE_ROLE=debug

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
load_role debug

[[ -n "${CLAUDE_NONINTERACTIVE:-}" ]] && export SSH_TARGET_NON_INTERACTIVE=1

source "$CODEGEN_DIR/harnesses/claude/ssh-target.sh"
resolve_ssh_target "$server" DEBUG claude-debug

DEBUG_CONTEXT="Server: ${DEBUG_ALIAS} (${server_resolved}), Login user: ${DEBUG_LOGIN_USER}, Operate-as: ${DEBUG_OPERATE_AS}, Environment: ${ENV_LABEL}"

DEBUG_STARTUP_MSG=$'## DEBUG STARTUP CONTEXT\n'"${DEBUG_CONTEXT}"$'\n\n## SSH cold-start self-check\nBefore investigating, confirm connectivity:\n  ssh '"${DEBUG_ALIAS}"$' "uptime && whoami"\nIf connection fails, stop and report to user — do not proceed on guesswork.\nOnce connected: read logs and config; do NOT run mutations.'

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

# Non-interactive: pass all non-interactive flags. Interactive: omit (claude handles tty detection).
NON_INTERACTIVE_FLAGS=()
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
    SETTINGS_JSON='{"env":{"MAX_THINKING_TOKENS":"16000"}}'
else
    SETTINGS_JSON='{"env":{"MAX_THINKING_TOKENS":"16000","CLAUDE_AFK_TIMEOUT_MS":"86400000"}}'
fi

CONTEXT_FLAGS=()
while IFS= read -r _cf; do
    [ -n "$_cf" ] || continue
    CONTEXT_FLAGS+=(--append-system-prompt "$(cat "$CODEGEN_DIR/$_cf")")
done <<<"$ROLE_CONTEXT_FILES"
CONTEXT_FLAGS+=(--append-system-prompt "${DEBUG_STARTUP_MSG}")

exec claude \
    --settings "$SETTINGS_JSON" \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
    "$@"
