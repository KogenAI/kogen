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

# Transform .md args to @-mentions for auto-load (mirrors claude-build.sh convention).
PROMPT_PARTS=()
for arg in "$@"; do
    if [[ "$arg" == *.md ]]; then
        PROMPT_PARTS+=("@$arg")
    else
        PROMPT_PARTS+=("$arg")
    fi
done

exec "$CODEGEN_DIR/codegen-build" \
    --harness=pi \
    --stack="${STACK:-phoenix}" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
