#!/usr/bin/env bash
# eex_render_test.sh — unit tests for eex_render.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$SCRIPT_DIR/eex_render.sh"

passed=0
failed=0
fail_lines=()

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then passed=$((passed + 1))
  else failed=$((failed + 1)); fail_lines+=("FAIL: $label"); fi
}

tmp="$(mktemp -d -t render-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

# Case 1: single binding substitution
echo 'Hello <%= name %>!' > "$tmp/t1.in"
"$RENDER" "$tmp/t1.in" "$tmp/t1.out" name=World
assert "single binding substituted" '[ "$(cat "$tmp/t1.out")" = "Hello World!" ]'

# Case 2: multiple bindings
echo 'app=<%= app_name %> mod=<%= app_name_module %>' > "$tmp/t2.in"
"$RENDER" "$tmp/t2.in" "$tmp/t2.out" app_name=my_app app_name_module=MyApp
assert "multiple bindings substituted" '[ "$(cat "$tmp/t2.out")" = "app=my_app mod=MyApp" ]'

# Case 3: unrecognized placeholder retained (no binding provided)
echo 'hi <%= unknown %>!' > "$tmp/t3.in"
"$RENDER" "$tmp/t3.in" "$tmp/t3.out" other=value
assert "unrecognized placeholder retained" 'grep -qF "<%= unknown %>" "$tmp/t3.out"'

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then printf '%s\n' "${fail_lines[@]}" >&2; exit 1; fi
