#!/usr/bin/env bash
# credo_live_strict_test.sh — verifies .credo.exs.eex has no _live.ex exclusions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EEX_RENDER="$SCRIPT_DIR/../eex_render.sh"
TEMPLATE="$SCRIPT_DIR/../templates/.credo.exs.eex"

passed=0
failed=0
fail_lines=()

assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        fail_lines+=("FAIL: $label")
    fi
}

# Render template to a temp file (no EEx variables needed — template is static)
TMP="$(mktemp "${TMPDIR:-/tmp}/credo-live-strict-XXXXXX")"
trap 'rm -f "$TMP"' EXIT

"$EEX_RENDER" "$TEMPLATE" "$TMP"

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert "no _live.ex occurrences in rendered output" \
    '! grep -q "_live\\.ex" "$TMP"'

assert "force: :meaningful is present" \
    'grep -qF "force: :meaningful" "$TMP"'

assert "VariableRebinding entry has no files exclude (bare [])" \
    'grep -qF "{Credo.Check.Refactor.VariableRebinding, []}" "$TMP"'

assert "_web.ex excludes are still present (regression sanity)" \
    'grep -qF "_web\\.ex" "$TMP"'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
