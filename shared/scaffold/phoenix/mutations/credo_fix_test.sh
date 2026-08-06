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

# ---------------------------------------------------------------------------
# Case 3: application.ex — strips skip_migrations?() zero-arity parens
# (only present when phx.new was invoked with --database; not in the base
# fixture skeleton, so synthesize the minimal reproducer inline).
# ---------------------------------------------------------------------------
tmp="$(setup_tmp)"
mkdir -p "$tmp/lib/fixture_app"
cat >"$tmp/lib/fixture_app/application.ex" <<'EOF'
defmodule FixtureApp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Ecto.Migrator,
        repos: Application.fetch_env!(:fixture_app, :ecto_repos), skip: skip_migrations?()}
    ]

    opts = [strategy: :one_for_one, name: FixtureApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end
end
EOF
"$MUTATION" "$tmp" FixtureApp >/dev/null
# The DEF loses its empty parens (Credo's ParenthesesOnZeroArityDefs); the
# CALL SITE keeps them — a bare `skip_migrations?` reference without parens
# there is parsed by Elixir as an undefined local variable, not a call, and
# fails to compile.
assert "application.ex: def skip_migrations? has no empty parens" \
    '! grep -qF "defp skip_migrations?() do" "$tmp/lib/fixture_app/application.ex"'
assert "application.ex: def skip_migrations? survives without parens" \
    'grep -qF "defp skip_migrations? do" "$tmp/lib/fixture_app/application.ex"'
assert "application.ex: call site skip_migrations?() keeps its parens" \
    'grep -qF "skip: skip_migrations?()}" "$tmp/lib/fixture_app/application.ex"'

# Idempotent — second invocation is a no-op
sha1_app="$(shasum "$tmp/lib/fixture_app/application.ex" | awk '{print $1}')"
"$MUTATION" "$tmp" FixtureApp >/dev/null
sha2_app="$(shasum "$tmp/lib/fixture_app/application.ex" | awk '{print $1}')"
assert "credo_fix.sh is idempotent for application.ex" '[ "$sha1_app" = "$sha2_app" ]'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
