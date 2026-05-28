#!/usr/bin/env bash
# Pi build launcher — analogous to claude-build.sh.
#
# PI_ROLE=build is exported before exec so hooks/guards that check PI_ROLE read it.
# Non-interactive execution uses `pi -p --mode json`.
# Model and effort read from config.yaml harness.build.pi block.
set -euo pipefail
export PI_ROLE=build

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

PROMPT_PARTS=()
READY_DIR="$PWD/codegen/pitches/ready"
for arg in "$@"; do
    if [[ "$arg" == */* ]] || [[ "$arg" == *.md ]] || [[ "$arg" == *" "* ]]; then
        PROMPT_PARTS+=("$arg")
        continue
    fi
    if [[ -f "$READY_DIR/${arg}.md" ]]; then
        PROMPT_PARTS+=("codegen/pitches/ready/${arg}.md")
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
        PROMPT_PARTS+=("codegen/pitches/ready/${matches[0]}.md")
    elif [[ ${#matches[@]} -gt 1 ]]; then
        printf 'pi-build: ambiguous basename %q; matches:\n' "$arg" >&2
        for m in "${matches[@]}"; do printf '  %s\n' "$m" >&2; done
        exit 1
    else
        PROMPT_PARTS+=("$arg")
    fi
done

exec "$CODEGEN_DIR/codegen-build" \
    --harness=pi \
    --stack="${STACK:-phoenix}" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
