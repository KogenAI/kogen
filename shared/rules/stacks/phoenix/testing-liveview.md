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

## Per-File Targeting

After editing LiveView: `mix test test/<app>_web/live/<file>_live_test.exs`. Never full suite.
