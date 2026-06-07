#!/usr/bin/env bash
# credo_fix_test.sh — unit tests for credo_fix.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/credo_fix.sh"
FIXTURE_BASE="$SCRIPT_DIR/../../../../test_harness/mutations/fixtures/phx_new_skeleton"

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

setup_tmp() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/credo-fix-XXXXXX")"
    cp -R "$FIXTURE_BASE/." "$tmp/"
    echo "$tmp"
}

# ---------------------------------------------------------------------------
# Case 1: happy path — adds @moduledoc to each FIX-bucket file
# ---------------------------------------------------------------------------
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" FixtureApp >/dev/null

assert "core_components.ex has @moduledoc" \
    'grep -qF "@moduledoc" "$tmp/lib/fixture_app_web/components/core_components.ex"'

assert "layouts.ex has @moduledoc" \
    'grep -qF "@moduledoc" "$tmp/lib/fixture_app_web/components/layouts.ex"'

assert "_web.ex has @moduledoc false" \
    'grep -qF "@moduledoc false" "$tmp/lib/fixture_app_web.ex"'

assert "page_controller.ex has @moduledoc false" \
    'grep -qF "@moduledoc false" "$tmp/lib/fixture_app_web/controllers/page_controller.ex"'

assert "error_html.ex has @moduledoc false" \
    'grep -qF "@moduledoc false" "$tmp/lib/fixture_app_web/controllers/error_html.ex"'

assert "error_json.ex has @moduledoc false" \
    'grep -qF "@moduledoc false" "$tmp/lib/fixture_app_web/controllers/error_json.ex"'

assert "page_controller.ex has @spec home or @spec index" \
    'grep -qE "@spec (home|index)" "$tmp/lib/fixture_app_web/controllers/page_controller.ex"'

assert "error_html.ex has @spec render" \
    'grep -qF "@spec render" "$tmp/lib/fixture_app_web/controllers/error_html.ex"'

assert "error_json.ex has @spec render" \
    'grep -qF "@spec render" "$tmp/lib/fixture_app_web/controllers/error_json.ex"'

rm -rf "$tmp"

# ---------------------------------------------------------------------------
# Case 2: idempotent — second invocation is a no-op (checksums stable)
# ---------------------------------------------------------------------------
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" FixtureApp >/dev/null

sha1_core="$(shasum "$tmp/lib/fixture_app_web/components/core_components.ex" | awk '{print $1}')"
sha1_layouts="$(shasum "$tmp/lib/fixture_app_web/components/layouts.ex" | awk '{print $1}')"
sha1_web="$(shasum "$tmp/lib/fixture_app_web.ex" | awk '{print $1}')"
sha1_page="$(shasum "$tmp/lib/fixture_app_web/controllers/page_controller.ex" | awk '{print $1}')"
sha1_ehtml="$(shasum "$tmp/lib/fixture_app_web/controllers/error_html.ex" | awk '{print $1}')"
sha1_ejson="$(shasum "$tmp/lib/fixture_app_web/controllers/error_json.ex" | awk '{print $1}')"

"$MUTATION" "$tmp" FixtureApp >/dev/null

sha2_core="$(shasum "$tmp/lib/fixture_app_web/components/core_components.ex" | awk '{print $1}')"
sha2_layouts="$(shasum "$tmp/lib/fixture_app_web/components/layouts.ex" | awk '{print $1}')"
sha2_web="$(shasum "$tmp/lib/fixture_app_web.ex" | awk '{print $1}')"
sha2_page="$(shasum "$tmp/lib/fixture_app_web/controllers/page_controller.ex" | awk '{print $1}')"
sha2_ehtml="$(shasum "$tmp/lib/fixture_app_web/controllers/error_html.ex" | awk '{print $1}')"
sha2_ejson="$(shasum "$tmp/lib/fixture_app_web/controllers/error_json.ex" | awk '{print $1}')"

assert "credo_fix.sh is idempotent for core_components.ex" '[ "$sha1_core" = "$sha2_core" ]'
assert "credo_fix.sh is idempotent for layouts.ex" '[ "$sha1_layouts" = "$sha2_layouts" ]'
assert "credo_fix.sh is idempotent for _web.ex" '[ "$sha1_web" = "$sha2_web" ]'
assert "credo_fix.sh is idempotent for page_controller.ex" '[ "$sha1_page" = "$sha2_page" ]'
assert "credo_fix.sh is idempotent for error_html.ex" '[ "$sha1_ehtml" = "$sha2_ehtml" ]'
assert "credo_fix.sh is idempotent for error_json.ex" '[ "$sha1_ejson" = "$sha2_ejson" ]'

rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
