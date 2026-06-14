#!/usr/bin/env bash
# wiring-check_test.sh — parse guard + verdict-logic tests for wiring-check.js
#
# Mirrors render-check_test.sh structure: node --check parse guard first,
# then ≥14 fixture-driven cases against real project-dir tmpdir fixtures.
# Each case: mktemp -d + trap cleanup; build fixture dirs; run node wiring-check.js;
# grep WIRING_VERDICT=.
#
# Summary line format: "N passed, N failed" (run-tests.sh discovers this).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIRING_JS="$SCRIPT_DIR/wiring-check.js"

pass=0
fail=0

# ── Assertion helpers ─────────────────────────────────────────────────────────

assert_verdict() {
    local desc="$1"
    local expected_prefix="$2"
    local actual="$3"
    if printf '%s' "$actual" | grep -qF "$expected_prefix"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected prefix: %s\n  actual output: %s\n' \
            "$desc" "$expected_prefix" "$actual"
        fail=$((fail + 1))
    fi
}

# ── Test 1: node --check parse guard ─────────────────────────────────────────
if node --check "$WIRING_JS" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: wiring-check.js node --check\n'
    pass=$((pass + 1))
else
    printf 'FAIL: wiring-check.js node --check — SyntaxError\n'
    node --check "$WIRING_JS" 2>&1 || true
    fail=$((fail + 1))
fi

# ── Test 2: PASS — phx-click with element-driven + :sys.get_state assert ─────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT
mkdir -p "$T2/lib/my_app_web" "$T2/test/my_app_web"
cat >"$T2/lib/my_app_web/draft.html.heex" <<'HEEX'
<div id="draft-container">
  <button id="draft" phx-click="save_draft">Save Draft</button>
</div>
HEEX
cat >"$T2/test/my_app_web/draft_live_test.exs" <<'EXUNIT'
defmodule MyApp.DraftLiveTest do
  use ExUnit.Case

  test "save draft calls GenServer" do
    {:ok, view, _html} = live(conn, ~p"/drafts")
    element("#draft") |> render_click()
    state = :sys.get_state(MyApp.DraftServer)
    assert state.saved == true
  end
end
EXUNIT
out2=$(node "$WIRING_JS" "$T2" 2>/dev/null)
assert_verdict "PASS: phx-click with :sys.get_state assert" "WIRING_VERDICT=PASS" "$out2"
trap - EXIT
rm -rf "$T2"

# ── Test 3: FAIL (label-only) — test only asserts html, no side-effect ───────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT
mkdir -p "$T3/lib/my_app_web" "$T3/test/my_app_web"
cat >"$T3/lib/my_app_web/draft.html.heex" <<'HEEX'
<button id="draft" phx-click="save_draft">Save Draft</button>
HEEX
cat >"$T3/test/my_app_web/draft_live_test.exs" <<'EXUNIT'
defmodule MyApp.DraftLiveTest do
  use ExUnit.Case

  test "clicking save shows confirmation" do
    {:ok, view, _html} = live(conn, ~p"/drafts")
    html = element("#draft") |> render_click()
    assert html =~ "Draft"
  end
end
EXUNIT
out3=$(node "$WIRING_JS" "$T3" 2>/dev/null)
assert_verdict "FAIL: label-only assert, no side-effect" "WIRING_VERDICT=FAIL:" "$out3"
# Must contain "draft" in the failure detail
if printf '%s' "$out3" | grep -qF "draft"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: FAIL detail contains draft\n'
    pass=$((pass + 1))
else
    printf 'FAIL: expected FAIL detail to contain "draft", got: %s\n' "$out3"
    fail=$((fail + 1))
fi
trap - EXIT
rm -rf "$T3"

# ── Test 4: FAIL — no test at all ────────────────────────────────────────────
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT
mkdir -p "$T4/lib/my_app_web" "$T4/test/my_app_web"
cat >"$T4/lib/my_app_web/page.html.heex" <<'HEEX'
<button id="submit-btn" phx-click="do_submit">Submit</button>
HEEX
cat >"$T4/test/my_app_web/page_live_test.exs" <<'EXUNIT'
defmodule MyApp.PageLiveTest do
  use ExUnit.Case

  test "page loads" do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Submit"
  end
end
EXUNIT
out4=$(node "$WIRING_JS" "$T4" 2>/dev/null)
assert_verdict "FAIL: handler exists but no driving test" "WIRING_VERDICT=FAIL:" "$out4"
if printf '%s' "$out4" | grep -qE "submit|do_submit"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: FAIL detail mentions the handler\n'
    pass=$((pass + 1))
else
    printf 'FAIL: expected FAIL detail to mention handler, got: %s\n' "$out4"
    fail=$((fail + 1))
fi
trap - EXIT
rm -rf "$T4"

# ── Test 5: FAIL:unresolvable-selector — interpolated phx-click value ────────
T5=$(mktemp -d)
trap 'rm -rf "$T5"' EXIT
mkdir -p "$T5/lib/my_app_web" "$T5/test/my_app_web"
cat >"$T5/lib/my_app_web/page.html.heex" <<'HEEX'
<button id="dyn" phx-click={"#{@dynamic_event}"}>Click</button>
HEEX
cat >"$T5/test/my_app_web/page_live_test.exs" <<'EXUNIT'
defmodule MyApp.PageLiveTest do
  use ExUnit.Case
  test "placeholder" do
    assert true
  end
end
EXUNIT
out5=$(node "$WIRING_JS" "$T5" 2>/dev/null)
assert_verdict "FAIL:unresolvable-selector: interpolated phx-click" \
    "WIRING_VERDICT=FAIL:unresolvable-selector:phx-click" "$out5"
trap - EXIT
rm -rf "$T5"

# ── Test 6: INCONCLUSIVE — no .heex file and no ~H sigil ─────────────────────
T6=$(mktemp -d)
trap 'rm -rf "$T6"' EXIT
mkdir -p "$T6/lib/my_app_web" "$T6/test/my_app_web"
cat >"$T6/lib/my_app_web/page.ex" <<'EX'
defmodule MyApp.PageLive do
  use Phoenix.LiveView
  def render(assigns), do: ~H"<p>Hello</p>"
end
EX
cat >"$T6/test/my_app_web/page_live_test.exs" <<'EXUNIT'
defmodule MyApp.PageLiveTest do
  use ExUnit.Case
  test "placeholder" do
    assert true
  end
end
EXUNIT
out6=$(node "$WIRING_JS" "$T6" 2>/dev/null)
assert_verdict "INCONCLUSIVE: no .heex and no ~H block sigil" \
    "WIRING_VERDICT=INCONCLUSIVE:no-heex" "$out6"
trap - EXIT
rm -rf "$T6"

# ── Test 7: PASS via ~H""" sigil in .ex file ─────────────────────────────────
T7=$(mktemp -d)
trap 'rm -rf "$T7"' EXIT
mkdir -p "$T7/lib/my_app_web" "$T7/test/my_app_web"
cat >"$T7/lib/my_app_web/page_live.ex" <<'EX'
defmodule MyApp.PageLive do
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <button id="send-btn" phx-click="send_message">Send</button>
    """
  end
end
EX
cat >"$T7/test/my_app_web/page_live_test.exs" <<'EXUNIT'
defmodule MyApp.PageLiveTest do
  use ExUnit.Case

  test "send message wires the action" do
    {:ok, view, _html} = live(conn, ~p"/")
    element("#send-btn") |> render_click()
    assert_received {:message_sent, _}
  end
end
EXUNIT
out7=$(node "$WIRING_JS" "$T7" 2>/dev/null)
assert_verdict "PASS: ~H sigil scanned for phx-click" "WIRING_VERDICT=PASS" "$out7"
trap - EXIT
rm -rf "$T7"

# ── Test 8: PASS via phx-window-keydown + render_keydown + assert_received ────
T8=$(mktemp -d)
trap 'rm -rf "$T8"' EXIT
mkdir -p "$T8/lib/my_app_web" "$T8/test/my_app_web"
cat >"$T8/lib/my_app_web/keyboard.html.heex" <<'HEEX'
<div id="keyboard-area" phx-window-keydown="handle_key">
  Press a key
</div>
HEEX
cat >"$T8/test/my_app_web/keyboard_live_test.exs" <<'EXUNIT'
defmodule MyApp.KeyboardLiveTest do
  use ExUnit.Case

  test "keydown triggers action" do
    {:ok, view, _html} = live(conn, ~p"/keyboard")
    element("#keyboard-area") |> render_keydown(%{"key" => "Enter"})
    assert_received {:key_handled, "Enter"}
  end
end
EXUNIT
out8=$(node "$WIRING_JS" "$T8" 2>/dev/null)
assert_verdict "PASS: phx-window-keydown + render_keydown + assert_received" \
    "WIRING_VERDICT=PASS" "$out8"
trap - EXIT
rm -rf "$T8"

# ── Test 9: PASS via ancestor id resolution ───────────────────────────────────
T9=$(mktemp -d)
trap 'rm -rf "$T9"' EXIT
mkdir -p "$T9/lib/my_app_web" "$T9/test/my_app_web"
cat >"$T9/lib/my_app_web/form.html.heex" <<'HEEX'
<div id="user-form">
  <section class="fields">
    <button phx-click="save_user">Save</button>
  </section>
</div>
HEEX
cat >"$T9/test/my_app_web/form_live_test.exs" <<'EXUNIT'
defmodule MyApp.FormLiveTest do
  use ExUnit.Case

  test "save user calls Mox expect" do
    MyApp.Repo
    |> expect(:insert!, fn _ -> {:ok, %{}} end)
    {:ok, view, _html} = live(conn, ~p"/form")
    element("#user-form") |> render_click()
    assert_received {:ok, _}
  end
end
EXUNIT
out9=$(node "$WIRING_JS" "$T9" 2>/dev/null)
assert_verdict "PASS: ancestor id resolution (handler on inner, id on parent)" \
    "WIRING_VERDICT=PASS" "$out9"
trap - EXIT
rm -rf "$T9"

# ── Test 10: FAIL — interpolated id on element AND interpolated ancestor id ───
T10=$(mktemp -d)
trap 'rm -rf "$T10"' EXIT
mkdir -p "$T10/lib/my_app_web" "$T10/test/my_app_web"
cat >"$T10/lib/my_app_web/dyn.html.heex" <<'HEEX'
<div id={@container_id}>
  <button id={@btn_id} phx-click="do_action">Click</button>
</div>
HEEX
cat >"$T10/test/my_app_web/dyn_live_test.exs" <<'EXUNIT'
defmodule MyApp.DynLiveTest do
  use ExUnit.Case
  test "placeholder" do
    assert true
  end
end
EXUNIT
out10=$(node "$WIRING_JS" "$T10" 2>/dev/null)
assert_verdict "FAIL:unresolvable-selector: interpolated id on element" \
    "WIRING_VERDICT=FAIL:unresolvable-selector:phx-click" "$out10"
trap - EXIT
rm -rf "$T10"

# ── Test 11: PASS — phx-submit with element render_submit + Mox expect ────────
T11=$(mktemp -d)
trap 'rm -rf "$T11"' EXIT
mkdir -p "$T11/lib/my_app_web" "$T11/test/my_app_web"
cat >"$T11/lib/my_app_web/login.html.heex" <<'HEEX'
<form id="login-form" phx-submit="do_login">
  <input name="email" />
  <button type="submit">Login</button>
</form>
HEEX
cat >"$T11/test/my_app_web/login_live_test.exs" <<'EXUNIT'
defmodule MyApp.LoginLiveTest do
  use ExUnit.Case

  test "login form submits and triggers auth" do
    MyApp.Auth
    |> expect(:authenticate, fn _ -> {:ok, %User{}} end)
    {:ok, view, _html} = live(conn, ~p"/login")
    element("#login-form") |> render_submit(%{email: "a@b.com"})
    assert_received {:authenticated, _}
  end
end
EXUNIT
out11=$(node "$WIRING_JS" "$T11" 2>/dev/null)
assert_verdict "PASS: phx-submit + element render_submit + Mox expect" \
    "WIRING_VERDICT=PASS" "$out11"
trap - EXIT
rm -rf "$T11"

# ── Test 12: PASS — phx-change with phx-value-key + render_change + File.exists? ─
T12=$(mktemp -d)
trap 'rm -rf "$T12"' EXIT
mkdir -p "$T12/lib/my_app_web" "$T12/test/my_app_web"
cat >"$T12/lib/my_app_web/upload.html.heex" <<'HEEX'
<input id="file-input" phx-change="file_selected" phx-value-key="user-id" />
HEEX
cat >"$T12/test/my_app_web/upload_live_test.exs" <<'EXUNIT'
defmodule MyApp.UploadLiveTest do
  use ExUnit.Case

  test "file selected writes to disk" do
    {:ok, view, _html} = live(conn, ~p"/upload")
    element("#file-input") |> render_change(%{"key" => "user-id"})
    assert File.exists?("/tmp/upload_user-id.tmp")
  end
end
EXUNIT
out12=$(node "$WIRING_JS" "$T12" 2>/dev/null)
assert_verdict "PASS: phx-change + render_change + File.exists? assert" \
    "WIRING_VERDICT=PASS" "$out12"
trap - EXIT
rm -rf "$T12"

# ── Test 13: FAIL — multiple handlers, only one wired, FAIL lists only unwired ─
T13=$(mktemp -d)
trap 'rm -rf "$T13"' EXIT
mkdir -p "$T13/lib/my_app_web" "$T13/test/my_app_web"
cat >"$T13/lib/my_app_web/panel.html.heex" <<'HEEX'
<button id="open-btn" phx-click="open_panel">Open</button>
<button id="close-btn" phx-click="close_panel">Close</button>
HEEX
cat >"$T13/test/my_app_web/panel_live_test.exs" <<'EXUNIT'
defmodule MyApp.PanelLiveTest do
  use ExUnit.Case

  test "open panel wires the action" do
    {:ok, view, _html} = live(conn, ~p"/panel")
    element("#open-btn") |> render_click()
    state = :sys.get_state(MyApp.PanelServer)
    assert state.open == true
  end

  test "close button page label only (no side-effect)" do
    {:ok, view, _html} = live(conn, ~p"/panel")
    html = element("#close-btn") |> render_click()
    assert html =~ "Closed"
  end
end
EXUNIT
out13=$(node "$WIRING_JS" "$T13" 2>/dev/null)
assert_verdict "FAIL: multiple handlers, only open-btn wired" "WIRING_VERDICT=FAIL:" "$out13"
# close-btn should be in the failure; open-btn should NOT be
if printf '%s' "$out13" | grep -qE "close"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unwired close-btn mentioned in FAIL detail\n'
    pass=$((pass + 1))
else
    printf 'FAIL: expected close handler in FAIL detail, got: %s\n' "$out13"
    fail=$((fail + 1))
fi
trap - EXIT
rm -rf "$T13"

# ── Test 14: PASS — element("button", "Save") text selector + side-effect ─────
T14=$(mktemp -d)
trap 'rm -rf "$T14"' EXIT
mkdir -p "$T14/lib/my_app_web" "$T14/test/my_app_web"
cat >"$T14/lib/my_app_web/editor.html.heex" <<'HEEX'
<div id="editor">
  <button phx-click="save_document">Save</button>
</div>
HEEX
cat >"$T14/test/my_app_web/editor_live_test.exs" <<'EXUNIT'
defmodule MyApp.EditorLiveTest do
  use ExUnit.Case

  test "save document via text selector" do
    {:ok, view, _html} = live(conn, ~p"/editor")
    element("button", "Save") |> render_click()
    assert_received {:document_saved, _}
  end
end
EXUNIT
out14=$(node "$WIRING_JS" "$T14" 2>/dev/null)
assert_verdict "PASS: element(tag, text) text selector with side-effect assert" \
    "WIRING_VERDICT=PASS" "$out14"
trap - EXIT
rm -rf "$T14"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
