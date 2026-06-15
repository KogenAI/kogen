#!/usr/bin/env bash
set -euo pipefail
# enforce-hook-rationale.sh — gate: every registry entry with harnesses: claude must carry
# a non-empty rationale field. Exits 1 listing offending ids; 0 on all-clear.
# Usage: enforce-hook-rationale.sh [<registry.yaml>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${1:-$SCRIPT_DIR/../../shared/enforcement/registry.yaml}"

if ! command -v yq >/dev/null 2>&1; then
    echo "enforce-hook-rationale: ERROR — yq not found on PATH (required: mikefarah/yq)" >&2
    exit 127
fi

missing=$(yq '.[] | select(.harnesses == "claude") | select((.rationale == null) or (.rationale == "")) | .id' "$REGISTRY")

if [ -n "$missing" ]; then
    while IFS= read -r id; do
        echo "enforce-hook-rationale: FAIL — $id (harnesses: claude) has no rationale"
    done <<<"$missing"
    exit 1
fi

[ -n "${VERBOSE:-}" ] && echo "enforce-hook-rationale: PASS"
exit 0
