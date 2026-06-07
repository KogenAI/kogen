# Testing — LiveView / HEEx / Browser

Frontend-specific. Shared rules → `stacks/phoenix/testing.md`.

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

## Per-File Targeting

After editing LiveView: `mix test test/<app>_web/live/<file>_live_test.exs`. Never full suite.
