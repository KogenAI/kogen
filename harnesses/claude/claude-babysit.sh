#!/usr/bin/env bash
# Babysit mode launcher — interactive drain supervisor. Ops-mold outer session
# (no --worktree, no draft-basename resolver): supervises the EXISTING
# codegen-build --queue drain + claude-shape entrypoint on a /loop cadence.
# --studio routes the drain to the resolved codegen-studio ssh target instead
# of running it locally.
set -euo pipefail
export CLAUDE_ROLE=babysit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${OCG_CODEGEN_DIR:-}" ]]; then
    CODEGEN_DIR="$OCG_CODEGEN_DIR"
elif [[ -L "$SCRIPT_DIR/harnesses" || -d "$SCRIPT_DIR/harnesses" ]]; then
    CODEGEN_DIR="$(cd -P "$SCRIPT_DIR/harnesses" && cd .. && pwd)"
else
    CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi
export CODEGEN_DIR

# Parse --studio BEFORE load_role so downstream context assembly can branch
# on it, and strip it from the positional args so it never leaks into the
# initial-prompt default below (pre-process flags before the resolver loop —
# same discipline as claude-shape's basename resolver).
STUDIO=0
INITIAL_PROMPT_ARGS=()
for _a in "$@"; do
    if [[ "$_a" == "--studio" ]]; then
        STUDIO=1
    else
        INITIAL_PROMPT_ARGS+=("$_a")
    fi
done

source "$CODEGEN_DIR/harnesses/claude/load-role.sh"
load_role babysit

BABYSIT_STARTUP_MSG=$'## BABYSIT STARTUP CONTEXT\n'

if [[ "$STUDIO" -eq 1 ]]; then
    export CODEGEN_BABYSIT_STUDIO=1
    source "$CODEGEN_DIR/harnesses/claude/ssh-target.sh"
    resolve_ssh_target studio BABYSIT claude-babysit
    BABYSIT_STARTUP_MSG+="Target: STUDIO — ${BABYSIT_ALIAS} (${server_resolved}), Login user: ${BABYSIT_LOGIN_USER}, Operate-as: ${BABYSIT_OPERATE_AS}. Before your FIRST dispatch to this target, run the remote build-ready preflight and refuse to dispatch remotely if it is red."
else
    BABYSIT_STARTUP_MSG+="Target: LOCAL — dispatch codegen-build --queue and claude-shape in this checkout."
fi

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

CONTEXT_FLAGS=()
while IFS= read -r _cf; do
    [ -n "$_cf" ] || continue
    CONTEXT_FLAGS+=(--append-system-prompt "$(cat "$CODEGEN_DIR/$_cf")")
done <<<"$ROLE_CONTEXT_FILES"
CONTEXT_FLAGS+=(--append-system-prompt "${BABYSIT_STARTUP_MSG}")

# Initial prompt: fires pass one immediately instead of opening to an empty
# input box. Literal procedure text — NOT "/babysit" — because the headless
# branch above sets --disable-slash-commands, making a slash payload inert
# there; literal text works identically on both branches. An operator-
# supplied positional argument REPLACES this default rather than appending
# to it (mirrors claude-shape's RESOLVED_ARGS convention).
if [[ ${#INITIAL_PROMPT_ARGS[@]} -gt 0 ]]; then
    RESOLVED_ARGS=("${INITIAL_PROMPT_ARGS[@]+"${INITIAL_PROMPT_ARGS[@]}"}")
else
    RESOLVED_ARGS=("Run one full pass of the standing supervision procedure now, then report the per-node verdict rows.")
fi

exec claude \
    "${SETTINGS_FLAGS[@]+"${SETTINGS_FLAGS[@]}"}" \
    "${NON_INTERACTIVE_FLAGS[@]+"${NON_INTERACTIVE_FLAGS[@]}"}" \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
    "${RESOLVED_ARGS[@]+"${RESOLVED_ARGS[@]}"}"
