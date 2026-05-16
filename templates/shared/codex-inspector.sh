#!/usr/bin/env bash
# Codex inspector launcher — analogous to claude-debug.sh.
#
# CODEX_ROLE=inspector is exported before exec so per_call_inspector hooks
# (codex-inspector-bash-guard.sh, codex-inspector-read-guard.sh,
# codex-inspector-write-guard.sh) activate correctly.
#
# System prompt injected via -c 'system_prompt="..."' (TOML config override).
# Interactive mode: user types prompts in the TUI.
set -euo pipefail
export CODEX_ROLE=inspector

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
export CODEGEN_DIR

SYSTEM_PROMPT_FILE="$CODEGEN_DIR/templates/shared/codex-inspector-system-prompt.txt"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "ERROR: codex-inspector-system-prompt.txt not found at $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
ROLE_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

cfg="${CODEGEN_DIR}/templates/generator/config.yaml"
ROLE_MODEL=$(yq -r ".harness.inspector.codex.model" "$cfg")

exec codex \
    -m "$ROLE_MODEL" \
    -c "system_prompt=$(printf '%s' "$ROLE_SYSTEM_PROMPT" | jq -Rs .)" \
    "$@"
