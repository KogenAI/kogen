#!/usr/bin/env bash
# telemetry_test.sh — unit tests for telemetry.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/telemetry.sh"
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

# Case 1: happy path — adds blank line between use Supervisor and import
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" fixture_app >/dev/null
assert "telemetry.ex has blank line between use Supervisor and import" \
  'python3 -c "
content = open(\"$tmp/lib/fixture_app_web/telemetry.ex\").read()
exit(0 if \"use Supervisor\n\n  import\" in content else 1)
"'
rm -rf "$tmp"

# Case 2: idempotent — second invocation is a no-op (file checksum stable)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" fixture_app >/dev/null
sha_after_first="$(shasum "$tmp/lib/fixture_app_web/telemetry.ex" | awk '{print $1}')"
"$MUTATION" "$tmp" fixture_app >/dev/null
sha_after_second="$(shasum "$tmp/lib/fixture_app_web/telemetry.ex" | awk '{print $1}')"
assert "telemetry.sh second invocation is a no-op" '[ "$sha_after_first" = "$sha_after_second" ]'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then printf '%s\n' "${fail_lines[@]}" >&2; exit 1; fi
