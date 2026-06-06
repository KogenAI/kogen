#!/usr/bin/env bash
# See context/claude-code-cli.md for:
#   - what --tools actually controls (built-in tools, NOT subagents)
#   - how the Agent tool is gated to only project subagents
#   - which built-in subagents are denied (Plan, general-purpose, statusline-setup
#     always; Explore allowed only under CLAUDE_ROLE=debug/shape/refactor)
set -euo pipefail

server="${1:?Usage: claude-debug <server> [claude args...]}"
shift

export CLAUDE_ROLE=debug

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/harnesses/claude/load-role.sh"
load_role debug

[[ -n "${CLAUDE_NONINTERACTIVE:-}" ]] && export SSH_TARGET_NON_INTERACTIVE=1

source "$CODEGEN_DIR/harnesses/claude/ssh-target.sh"
resolve_ssh_target "$server" DEBUG claude-debug

DEBUG_CONTEXT="Server: ${server_resolved} (resolved from '${server}'), Environment: ${ENV_LABEL}"

DEBUG_STARTUP_MSG=$'## DEBUG STARTUP CONTEXT\n'"${DEBUG_CONTEXT}"$'\n\n## SSH cold-start self-check\nBefore investigating, confirm connectivity:\n  ssh '"${server_resolved}"$' "uptime && whoami"\nIf connection fails, stop and report to user — do not proceed on guesswork.\nOnce connected: read logs and config; do NOT run mutations.'

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
fi

exec claude \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    --append-system-prompt "${DEBUG_STARTUP_MSG}" \
    "$@"
