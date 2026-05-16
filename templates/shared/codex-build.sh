#!/usr/bin/env bash
# Codex build launcher — analogous to claude-build.sh.
#
# Codex CLI does not have a --system-prompt flag. System prompt is injected
# via -c 'system_prompt="..."' (TOML config override, applied per-invocation).
# Model is set via -m <model>. Non-interactive execution uses `codex exec`.
#
# CODEX_ROLE=build is exported before exec so hooks that check CODEX_ROLE read it.
set -euo pipefail
export CODEX_ROLE=build

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

source "$CODEGEN_DIR/templates/shared/load-role.sh"
# build role in config.yaml only has model/effort for codex; no system_prompt_file —
# read system prompt from the shared codex-build-system-prompt.txt.
SYSTEM_PROMPT_FILE="$CODEGEN_DIR/templates/shared/codex-build-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: codex-build-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.build.codex.model" "$cfg")

# Transform .md args to @-mentions for auto-load (mirrors claude-build.sh convention;
# Codex does not yet support @-file auto-load but the convention is preserved for
# forward compatibility and so callers can pass doc paths uniformly).
PROMPT_PARTS=()
for arg in "$@"; do
    if [[ "$arg" == *.md ]]; then
        PROMPT_PARTS+=("@$arg")
    else
        PROMPT_PARTS+=("$arg")
    fi
done

exec codex exec \
    -m "$ROLE_MODEL" \
    --dangerously-bypass-approvals-and-sandbox \
    -c "system_prompt=$(printf '%s' "$ROLE_SYSTEM_PROMPT" | jq -Rs .)" \
    "${PROMPT_PARTS[@]+"${PROMPT_PARTS[@]}"}"
