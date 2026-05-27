#!/usr/bin/env bash
# mix_exs_test.sh — unit tests for mix_exs.sh (one case per Step 1-5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/mix_exs.sh"
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

# Run mutation once — all 5 steps are applied
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" fixture_app FixtureApp >/dev/null

# Case 1: Step 1 — credo + tidewave injected before lazy_html
assert "Step 1: credo dep present" 'grep -qF "{:credo," "$tmp/mix.exs"'
assert "Step 1: tidewave dep present" 'grep -qF "{:tidewave," "$tmp/mix.exs"'

# Case 2: Step 2 — ecto.setup alias replaced
assert "Step 2: ecto.setup alias present" 'grep -qF "\"ecto.setup\":" "$tmp/mix.exs"'

# Case 3: Step 3 — def cli do block inserted with sobelow preferred_env
assert "Step 3: sobelow preferred env present" 'grep -qF "sobelow: :test" "$tmp/mix.exs"'

# Case 4: Step 4 — dialyzer plt_file injected into project
assert "Step 4: plt_file present" 'grep -qF "plt_file: {:no_warn" "$tmp/mix.exs"'

# Case 5: Step 5 — defp phoenix_deps restructure
assert "Step 5: phoenix_deps function defined" 'grep -qF "defp phoenix_deps do" "$tmp/mix.exs"'

rm -rf "$tmp"

# Case 6: idempotent — second invocation is a no-op (file checksum stable)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" fixture_app FixtureApp >/dev/null
sha_after_first="$(shasum "$tmp/mix.exs" | awk '{print $1}')"
"$MUTATION" "$tmp" fixture_app FixtureApp >/dev/null
sha_after_second="$(shasum "$tmp/mix.exs" | awk '{print $1}')"
assert "mix_exs.sh second invocation is a no-op" '[ "$sha_after_first" = "$sha_after_second" ]'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
