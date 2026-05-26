#!/usr/bin/env bash
# See context/claude-code-cli.md for:
#   - what --tools actually controls (built-in tools, NOT subagents)
#   - how the Agent tool is gated to only project subagents
#   - which built-in subagents are denied (Plan, general-purpose, statusline-setup
#     always; Explore allowed only under CLAUDE_ROLE=debug/shape/refactor)
set -euo pipefail
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

# Basename resolver (permissive) against $PWD/codegen/pitches/ready/
# 1. Contains / or ends in .md or contains space → pass through unchanged.
# 2. codegen/pitches/ready/<arg>.md exists → @-mention it.
# 3. Exactly one prefix match → @-mention it.
# 4. Multiple prefix matches → error + list + exit 1.
# 5. No match → pass through unchanged (preserves Elixir runner free-form-prompt path).
PROMPT_PARTS=()
READY_DIR="$PWD/codegen/pitches/ready"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        PROMPT_PARTS+=("$arg")
        continue
    fi
    if [[ -f "$READY_DIR/${arg}.md" ]]; then
        PROMPT_PARTS+=("@codegen/pitches/ready/${arg}.md")
        continue
    fi
    matches=()
    if [[ -d "$READY_DIR" ]]; then
        while IFS= read -r -d '' f; do
            bn="$(basename "$f" .md)"
            if [[ "$bn" == "${arg}"* ]]; then
                matches+=("$bn")
            fi
        done < <(find "$READY_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
        PROMPT_PARTS+=("@codegen/pitches/ready/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'claude-build: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        # Permissive: no match → pass through as literal prompt token
        PROMPT_PARTS+=("$arg")
    fi
done

exec "$CODEGEN_DIR/codegen-build" \
    --harness=claude \
    --stack="${STACK:-phoenix}" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
