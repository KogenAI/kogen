#!/usr/bin/env bash
# coveralls_test.sh — unit tests for coveralls.json.eex template rendering
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/coveralls.json.eex"
RENDER_SH="$SCRIPT_DIR/../eex_render.sh"

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

# Render the template into a temp file with app_name=myapp
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/coveralls-XXXXXX.json")"
trap 'rm -f "$TMP_OUT"' EXIT

"$RENDER_SH" "$TEMPLATE" "$TMP_OUT" "app_name=myapp" "app_name_module=Myapp"

# Case 1: rendered file is valid JSON (jq parses without error)
assert "coveralls.json renders as valid JSON" 'jq . "$TMP_OUT" >/dev/null 2>&1'

# Case 2: existing skip entry preserved
assert "release.ex skip entry present" 'grep -qF "lib/myapp/release.ex" "$TMP_OUT"'

# Case 3: new boilerplate skip entries present
assert "core_components.ex skip entry present" 'grep -qF "lib/myapp_web/components/core_components.ex" "$TMP_OUT"'
assert "layouts.ex skip entry present" 'grep -qF "lib/myapp_web/components/layouts.ex" "$TMP_OUT"'
assert "endpoint.ex skip entry present" 'grep -qF "lib/myapp_web/endpoint.ex" "$TMP_OUT"'
assert "gettext.ex skip entry present" 'grep -qF "lib/myapp_web/gettext.ex" "$TMP_OUT"'
assert "telemetry.ex skip entry present" 'grep -qF "lib/myapp_web/telemetry.ex" "$TMP_OUT"'
assert "app.ex skip entry present" 'grep -qF "lib/myapp.ex" "$TMP_OUT"'
assert "app_web.ex skip entry present" 'grep -qF "lib/myapp_web.ex" "$TMP_OUT"'

# Case 4: minimum_coverage is still present
assert "minimum_coverage present" 'jq -e ".coverage_options.minimum_coverage" "$TMP_OUT" >/dev/null 2>&1'

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
