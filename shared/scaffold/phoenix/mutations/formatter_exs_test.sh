#!/usr/bin/env bash
# formatter_exs_test.sh — unit tests for formatter_exs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/formatter_exs.sh"
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
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/mut-XXXXXX")"
    cp -R "$FIXTURE_BASE/." "$tmp/"
    echo "$tmp"
}

# Case 1: happy path — adds DoctestFormatter to plugins
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
assert ".formatter.exs has DoctestFormatter" 'grep -qF "DoctestFormatter" "$tmp/.formatter.exs"'
rm -rf "$tmp"

# Case 2: idempotent — second invocation is a no-op (file checksum stable)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
sha_after_first="$(shasum "$tmp/.formatter.exs" | awk '{print $1}')"
"$MUTATION" "$tmp" >/dev/null
sha_after_second="$(shasum "$tmp/.formatter.exs" | awk '{print $1}')"
assert "formatter_exs.sh second invocation is a no-op" '[ "$sha_after_first" = "$sha_after_second" ]'
rm -rf "$tmp"

# Case 3: missing anchor — script exits 1 and emits ERROR on stderr
# Remove Phoenix.LiveView.HTMLFormatter so the sed substitution produces no match
# and DoctestFormatter is absent from the output
tmp="$(setup_tmp)"
sed 's/Phoenix\.LiveView\.HTMLFormatter/SomeOtherFormatter/' "$tmp/.formatter.exs" >"$tmp/.formatter.exs.tmp" && mv "$tmp/.formatter.exs.tmp" "$tmp/.formatter.exs"
missing_anchor_exit=0
missing_anchor_out="$("$MUTATION" "$tmp" 2>&1)" || missing_anchor_exit=$?
assert "formatter_exs missing anchor exits 1" '[ "$missing_anchor_exit" -eq 1 ]'
assert "formatter_exs missing anchor emits ERROR message" 'echo "$missing_anchor_out" | grep -qi "ERROR\|post-condition\|DoctestFormatter"'
rm -rf "$tmp"

# Case 4: --no-ecto strips :ecto and :ecto_sql from import_deps
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" --no-ecto >/dev/null
assert "--no-ecto: :ecto atom removed from import_deps" \
    '! grep -qE ":(ecto|ecto_sql)" "$tmp/.formatter.exs"'
assert "--no-ecto: :phoenix atom retained" \
    'grep -qF ":phoenix" "$tmp/.formatter.exs"'
assert "--no-ecto: DoctestFormatter still added" \
    'grep -qF "DoctestFormatter" "$tmp/.formatter.exs"'
rm -rf "$tmp"

# Case 5: --no-ecto removes the migrations subdirectory line
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" --no-ecto >/dev/null
assert "--no-ecto: migrations subdirectory line removed" \
    '! grep -q "subdirectories.*migrations" "$tmp/.formatter.exs"'
rm -rf "$tmp"

# Case 6: without --no-ecto, ecto atoms are retained
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
assert "without --no-ecto: :ecto_sql retained" \
    'grep -qF ":ecto_sql" "$tmp/.formatter.exs"'
assert "without --no-ecto: migrations subdirectory retained" \
    'grep -q "subdirectories.*migrations" "$tmp/.formatter.exs"'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
