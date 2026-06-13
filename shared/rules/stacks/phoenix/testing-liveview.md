# Testing — LiveView / HEEx / Browser

Frontend-specific. Shared testing rules appear earlier in this prompt.

## LiveView Testing

```elixir
# Navigation after submit
assert {:error, {:live_redirect, %{to: path}}} =
  view |> form("#form-id", job: attrs) |> render_submit()
{:ok, new_view, _html} = live(conn, path)

# Events
html = render_hook(live_view, "filter_jobs", %{"type" => "remote"})
html = view |> form("#job-form", job: %{type: "remote"}) |> render_change()
html = view |> element("button#load-more") |> render_click()
```

- Mount: `{:ok, view, html} = live(conn, "/path")`
- Components through LiveView only, never standalone
- Assert on rendered text/markup, not assigns
- `assert_redirect`, `assert_patch` for navigation
- `render_async/1` to wait for `handle_info`

**A LiveView Test Per Interactive Handler (MUST).**
Every `phx-click`/`phx-submit`/`phx-change`/`phx-keyup`/`phx-window-keydown` handler MUST have a LiveView test that drives it through the REAL rendered element and asserts the observable outcome:

```elixir
{:ok, view, _html} = live(conn, "/")
view |> element("#start-build") |> render_click()
assert render(view) =~ "building"          # re-render shows the new state
assert_received {:build_started, _slug}    # the side effect actually fired
```

Select the REAL element (`element("#id")` / `element("button", "Start")`), NOT `render_click(view, "event", %{})` with a hand-fed event name — the hand-fed form bypasses the rendered wiring, which is the exact thing being verified. For a side effect crossing a process boundary, assert via an observable signal (message to the test pid through the PUBLIC protocol, a file existing, a GenServer state query) — NEVER a test-pid injected into prod code (already forbidden here). A handler with no such test is a blocking review issue. **Browser tests are NOT required** — client-JS-only behavior (keyboard map, focus-on-open, hold-Space, backdrop click-through) gets a ONE-TIME manual browser smoke noted in the session log, not a Wallaby/Playwright suite. A handler whose contract IS a state change MUST assert the REAL effect crossing a boundary (DB row, file, message to test pid via public protocol, GenServer state) — asserting ONLY `render(view) =~ "..."` for a state-change handler is a blocking review issue: the rendered string can lag, be hard-coded, or render into a blank shell.

**Render-Proof — Mount With Real Data (MUST).**
Every routed LiveView MUST have a test that mounts WITH REPRESENTATIVE DATA PRESENT and asserts the PRIMARY content region (the routed view's main data area, NOT the layout shell, nav, or header) contains ≥1 expected data row. The fixture MUST supply real domain data. A test that mounts with an empty/nil data source and asserts only shell fragments (title, nav label, container `id`) is explicitly FORBIDDEN — it passes on a blank page. The empty-state ("no records yet") case is a SEPARATE test. Assert specific data text (`assert html =~ "Remote Developer"`), never just `assert html =~ "Jobs"`.

**phx-click Bubbling — Dismiss Only On The Intended Target.**
A `phx-click` on an outer container fires for ALL descendant clicks (events bubble). Put close handlers on a backdrop-only element, gate on `e.target === e.currentTarget` in a hook, or stop propagation on the panel. Acceptance: clicking inside the panel keeps it open; clicking the backdrop closes it. LiveView-testable: a click on a panel element does NOT close; a click on the backdrop element DOES. FORBIDDEN: BOTH a server `phx-click` close handler AND a client-side JS guard (e.g., `phx-click-away` hook or `e.target === e.currentTarget` check) on the SAME element — pick ONE close mechanism; doubling them causes double-fire or mutual cancellation. Server handler OR client guard, never both.

## Selector Discipline

✅ `#id`, `data-test="..."`, semantic roles. ❌ Tailwind class selectors. ❌ nth-child / structural.

## Behavior Not Loading

```elixir
# ❌ asserts page loaded
assert html =~ "Jobs"
# ✅ asserts feature works
assert html =~ "Remote Developer"
refute html =~ "Filtered Out Job"
```

## Browser / Feature (Wallaby)

- `test/features/**/*_test.exs` with `@moduletag :feature` or Cucumber
- `async: false` for browser sessions (single Chromedriver pool)
- Screenshot on failure: `take_screenshot(session)` in `on_exit`
- ❌ Assert on transient DOM during animations — use `assert_has` (retries)

## SPA / Client-Rendered

Vite/JS-mounted views: feature text in JS bundles, not server HTML.

❌ `assert response.body =~ ~r/step size/i`
✅ `grep -ri "step size" assets/`

## Refactoring

Update LiveView tests only. EXCLUDE feature/browser tests from selector-rename sweeps.

## Dead-Render Placeholder Correctness

Every assign key that the **template** reads must be set on **BOTH** render passes (dead + connect). Hooks (`on_mount`) count as setters — do NOT re-check hook-owned keys in the LiveView's own dead-render branch.

Verification checklist per LiveView:

1. List all assigns referenced in templates (e.g., `@streams.items`, `@total_count`, `@loading?`)
2. For each key: mark where it is initialized (hook? mount? handle_params? handle_event?)
3. If initialized by `on_mount` — key is SAFE on dead render (hook runs both passes)
4. If initialized in connected path only (e.g., DB load guarded by `connected?`) — must assign placeholder on dead render
5. Streams MUST be initialized via `stream/3` on both paths (call `stream(..., [], reset: true)` even if data-guarded)

Example: `DropLive.Index` template reads `@streams.drops`, `@drops_empty?`, `@end_of_timeline?`, `@loading_more`. On dead render, `handle_params/3` else branch sets all four; stream is initialized, booleans set to safe defaults. Connected branch loads data and overwrites the same keys. Dead render assignment is NOT redundant — it ensures the keys exist on WS connect before the async `load_more` fires.

## Test Seams in Production Code — Forbidden

❌ Injecting `Application.get_env` keys into `channel.ex`, `live_view.ex`, or other production code to signal test conditions (e.g., `Application.get_env(:app, :test_pid)` to `send` assertions to a test process). Test hooks in production are a **blocking review issue**.

Symptom: production module reads `Application.get_env(:my_app, :test_callback)` and calls it if non-nil. This couples prod code to test infrastructure and complicates testing of the prod path itself.

Solution: use observable signals already present in the LiveView protocol. Example: WS join reply includes `{:ok, %{"resume" => true}}` — tests assert on the join reply's `warm: true` or `resume: true` fields instead of reaching into application config. The observable signal documents the feature boundary and proves production code is exercising it.

Pattern: test-assertion source of truth is the public protocol (join reply, rendered HTML, LiveView assigns visible in test), not private application env keys. Tests that work through the public surface automatically test the prod path.

## Per-File Targeting

After editing LiveView: `mix test test/<app>_web/live/<file>_live_test.exs`. Never full suite.

## LiveView UI

- WHAT not THAT: ❌ `render_display_components` → ✅ `display_components`
- Alphabetical attrs in `attr` AND HEEx
- `:if` simple; `<%= if %>` multi-element-with-else
- `Phoenix.Component.used_input?/1` for error display
- `phx-debounce` on **fields**, not `<.form>`
- JS hooks: import in `app.js`, alphabetical
- `Phoenix.JS` for instant client-side
- Search dropdowns: never mix Phoenix handlers with JS hooks; `tabindex="0"` on clickable items
- `cursor-pointer` on interactive; padding/bg on `<.link>` with `block`
- Explicit helper fns — `Media.get_media_asset_url(@media_asset)`
- npm: `cd assets` first
- `phx-change`/`phx-keyup`/`phx-submit` require a `<form>` ancestor — inputs outside a `<form>` silently no-op with NO console error; wrap event-handling inputs in `<.form>` or a bare `<form>` tag
- `live_render` of a child LiveView MUST set `layout: false` to avoid double-layout render; the routed root LiveView owns the layout
- Autofocus-on-open: `<input phx-mounted={JS.focus()} />` — use for keyboard-first overlays/modals so the caret lands without a click

## Pitfall — LazyHTML

First LiveView test using `render_change`/`render_click`/`element` → `Protocol.UndefinedError: protocol Enumerable not implemented for LazyHTML`. Fix:

```bash
MIX_ENV=test mix deps.compile --force lazy_html phoenix_live_view && MIX_ENV=test mix compile --force
```
