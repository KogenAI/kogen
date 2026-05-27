#!/usr/bin/env bash
# router_test.sh — unit tests for router.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/router.sh"
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
    tmp="$(mktemp -d -t mut-XXXXXX)"
    cp -R "$FIXTURE_BASE/." "$tmp/"
    echo "$tmp"
}

# Case 1: happy path — inserts HealthController route
# (router.sh lowercases APP_NAME_MODULE to derive path; FixtureApp -> fixtureapp_web
#  but fixture has fixture_app_web, so find fallback is used)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" FixtureApp >/dev/null
assert "router.ex has HealthController route" 'grep -qF "HealthController" "$tmp/lib/fixture_app_web/router.ex"'
rm -rf "$tmp"

# Case 2: idempotent — second invocation is a no-op (file checksum stable)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" FixtureApp >/dev/null
sha_after_first="$(shasum "$tmp/lib/fixture_app_web/router.ex" | awk '{print $1}')"
"$MUTATION" "$tmp" FixtureApp >/dev/null
sha_after_second="$(shasum "$tmp/lib/fixture_app_web/router.ex" | awk '{print $1}')"
assert "router.sh second invocation is a no-op" '[ "$sha_after_first" = "$sha_after_second" ]'
rm -rf "$tmp"

# Case 3: fallback-find — router at non-standard path (underscore in module name)
# Move router to a path that doesn't match the lowercased module derivation, ensure find picks it up
tmp="$(setup_tmp)"
# Rename router to unusual path (find still discovers it via -name router.ex -path "*_web*")
mkdir -p "$tmp/lib/other_app_web"
mv "$tmp/lib/fixture_app_web/router.ex" "$tmp/lib/other_app_web/router.ex"
rmdir "$tmp/lib/fixture_app_web" 2>/dev/null || true
"$MUTATION" "$tmp" FixtureApp >/dev/null
assert "fallback-find: HealthController route added when router at non-standard path" \
    'grep -qF "HealthController" "$tmp/lib/other_app_web/router.ex"'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
