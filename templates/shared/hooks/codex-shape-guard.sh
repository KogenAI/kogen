#!/bin/bash
# codex-shape-guard.sh — PreToolUse apply_patch hook for Codex Shape/Refactor sessions.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: apply_patch
# surface: per_call_inspector
# signal: CODEX_ROLE
# role: codex-shape, codex-refactor
# harnesses: claude_code
# rationale: Codex-specific shape mode guard
#
# Blocks apply_patch writes to paths outside codegen/pitches/ when CODEX_ROLE=shape or CODEX_ROLE=refactor.
# Codex apply_patch carries a unified-diff patch body; target paths are parsed from
# "+++ <path>" lines in the patch content.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

# Only active when CODEX_ROLE=shape or CODEX_ROLE=refactor.
[ "${CODEX_ROLE:-}" = "shape" ] || [ "${CODEX_ROLE:-}" = "refactor" ] || exit 0

# Only gate apply_patch.
if ! printf '%s' "$TOOL_NAME" | grep -qE '^apply_patch$'; then
    exit 0
fi

# Extract patch body from tool_input.patch.
patch_body=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.patch // ""' 2>/dev/null)

if [ -z "$patch_body" ]; then
    # No patch body — let the tool handle it.
    exit 0
fi

# Parse target paths from "+++ <path>" lines (unified-diff format).
# Strip the "b/" prefix that git-format unified diffs add.
target_paths=$(printf '%s' "$patch_body" | grep -oE '^\+\+\+ [^ ]+' | sed 's|^\+\+\+ b/||; s|^\+\+\+ ||' || true)

if [ -z "$target_paths" ]; then
    # No target paths found — allow (tool will handle malformed input).
    exit 0
fi

# Check every target path is under codegen/pitches/.
while IFS= read -r path; do
    [ -z "$path" ] && continue
    # Allow /dev/null (deleted-file marker in unified diffs).
    [ "$path" = "/dev/null" ] && continue
    # Normalise: strip leading ./ if present.
    rel_path="${path#./}"
    if ! printf '%s' "$rel_path" | grep -qE '^codegen/pitches/'; then
        deny "BLOCKED by codex-shape-guard: CODEX_ROLE=${CODEX_ROLE:-} may only write to codegen/pitches/ — patch target path '$path' is outside this boundary"
        exit 0
    fi
done <<<"$target_paths"

exit 0
