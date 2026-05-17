#!/usr/bin/env bash
# See context/claude-code-cli.md for:
#   - what --tools actually controls (built-in tools, NOT subagents)
#   - how the Agent tool is gated to only project subagents
#   - which built-in subagents are denied (Plan, general-purpose, statusline-setup
#     always; Explore allowed only under CLAUDE_ROLE=debug/shape/refactor)
set -euo pipefail
export CLAUDE_ROLE=shape

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/templates/shared/load-role.sh"
load_role shape

CONTEXT_FLAGS=()
if [[ -f "./PROJECT_CONTEXT.md" ]]; then
    CONTEXT_FLAGS+=(--append-system-prompt "$(cat ./PROJECT_CONTEXT.md)")
fi

TOOL_FLAGS=()
if [ -n "$ROLE_TOOLS" ]; then
    TOOL_FLAGS+=(--tools "$ROLE_TOOLS")
elif [ -n "$ROLE_DISALLOWED" ]; then
    TOOL_FLAGS+=(--disallowed-tools "$ROLE_DISALLOWED")
fi

# Cold-start: no args → open conversation directly, model asks "What problem are you trying to solve?"
if [[ $# -eq 0 ]]; then
    exec claude \
        --model "$ROLE_MODEL" \
        --effort "$ROLE_EFFORT" \
        --dangerously-skip-permissions \
        "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
        --system-prompt "$ROLE_SYSTEM_PROMPT" \
        "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}"
fi

# Basename resolver (strict) against $PWD/codegen/pitches/draft/
# 1. Contains / or ends in .md or contains space → pass through unchanged.
# 2. codegen/pitches/draft/<arg>.md exists → @-mention it.
# 3. Exactly one prefix match → @-mention it.
# 4. Multiple prefix matches → error + list + exit 1.
# 5. No match → error + exit 1.
RESOLVED_ARGS=()
DRAFT_DIR="$PWD/codegen/pitches/draft"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        RESOLVED_ARGS+=("$arg")
        continue
    fi
    if [[ -f "$DRAFT_DIR/${arg}.md" ]]; then
        RESOLVED_ARGS+=("@codegen/pitches/draft/${arg}.md")
        continue
    fi
    matches=()
    if [[ -d "$DRAFT_DIR" ]]; then
        while IFS= read -r -d '' f; do
            bn="$(basename "$f" .md)"
            if [[ "$bn" == "${arg}"* ]]; then
                matches+=("$bn")
            fi
        done < <(find "$DRAFT_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
        RESOLVED_ARGS+=("@codegen/pitches/draft/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'claude-shape: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        printf 'claude-shape: no draft matching %q in codegen/pitches/draft/\n' "$arg" >&2
        exit 1
    fi
done

exec claude \
    --model "$ROLE_MODEL" \
    --effort "$ROLE_EFFORT" \
    --dangerously-skip-permissions \
    "${TOOL_FLAGS[@]+"${TOOL_FLAGS[@]}"}" \
    --system-prompt "$ROLE_SYSTEM_PROMPT" \
    "${CONTEXT_FLAGS[@]+"${CONTEXT_FLAGS[@]}"}" \
    "${RESOLVED_ARGS[@]+"${RESOLVED_ARGS[@]}"}"
