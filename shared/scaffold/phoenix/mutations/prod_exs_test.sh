#!/usr/bin/env bash
# prod_exs_test.sh — unit tests for prod_exs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/prod_exs.sh"
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

# Case 1: happy path — creates config/prod.exs with import Config
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
assert "config/prod.exs created" '[ -f "$tmp/config/prod.exs" ]'
assert "config/prod.exs has import Config" 'grep -qF "import Config" "$tmp/config/prod.exs"'
rm -rf "$tmp"

# Case 2: idempotent — if prod.exs already exists, does not overwrite it
# Write a sentinel value, re-run, sentinel must survive
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
printf 'import Config\n# sentinel-value-xyz\n' > "$tmp/config/prod.exs"
"$MUTATION" "$tmp" >/dev/null
assert "prod_exs.sh does not overwrite existing file (sentinel survives)" 'grep -qF "sentinel-value-xyz" "$tmp/config/prod.exs"'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then printf '%s\n' "${fail_lines[@]}" >&2; exit 1; fi
