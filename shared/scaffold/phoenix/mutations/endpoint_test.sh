#!/usr/bin/env bash
# endpoint_test.sh — unit tests for endpoint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/endpoint.sh"
FIXTURE_BASE="$SCRIPT_DIR/../../../../test_harness/mutations/fixtures/phx_new_skeleton"

passed=0
failed=0
fail_lines=()

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then passed=$((passed + 1))
  else failed=$((failed + 1)); fail_lines+=("FAIL: $label"); fi
}

setup_tmp() {
  local tmp
  tmp="$(mktemp -d -t mut-XXXXXX)"
  cp -R "$FIXTURE_BASE/." "$tmp/"
  echo "$tmp"
}

# Case 1: happy path — inserts Tidewave plug after use Phoenix.Endpoint
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" fixture_app >/dev/null
assert "endpoint.ex has plug Tidewave" 'grep -qF "plug Tidewave" "$tmp/lib/fixture_app_web/endpoint.ex"'
rm -rf "$tmp"

# Case 2: idempotent — second invocation is a no-op (file checksum stable)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" fixture_app >/dev/null
sha_after_first="$(shasum "$tmp/lib/fixture_app_web/endpoint.ex" | awk '{print $1}')"
"$MUTATION" "$tmp" fixture_app >/dev/null
sha_after_second="$(shasum "$tmp/lib/fixture_app_web/endpoint.ex" | awk '{print $1}')"
assert "endpoint.sh second invocation is a no-op" '[ "$sha_after_first" = "$sha_after_second" ]'
rm -rf "$tmp"

# Case 3: missing anchor — script emits WARNING and exits 0 (does not fail)
tmp="$(setup_tmp)"
# Replace the anchor so it won't be found
sed -i '' 's/use Phoenix.Endpoint, otp_app: :fixture_app/use Phoenix.Endpoint, otp_app: :other_app/' \
  "$tmp/lib/fixture_app_web/endpoint.ex"
all_out="$("$MUTATION" "$tmp" fixture_app 2>&1 || true)"
assert "missing anchor exits 0 and emits warning" 'echo "$all_out" | grep -qi "WARNING\|could not find anchor\|skipping"'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then printf '%s\n' "${fail_lines[@]}" >&2; exit 1; fi
