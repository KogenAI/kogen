# Phoenix / Elixir — Core

Cross-role facts. Idioms, Ecto, contexts, LiveView UI.

## Slice Scope

- **backend**: `lib/<app>/`, `priv/repo/migrations/`, seeds, fixtures, Oban, mailers, contexts, controllers, plugs.
- **frontend**: LiveView render, HEEx, function components, JS hooks, Tailwind, browser tests.

## Migrations

- Additive-first: nullable cols over altering
- No destructive defaults — never `NOT NULL` without default or two-step
- Reversible `change/0`. Irreversible → `up/0` + `down/0` with `raise "irreversible"`
- Table-rename: update FK refs same migration. `rename table(...)`, never drop-and-recreate
- Long index names: pass `name:` (Postgres 63-char limit)

## Scope-Based Authorization

Pass scope to context fns. Handle nil as not-found-OR-not-authorized.

```elixir
case JobPostings.get_job_posting(socket.assigns.current_scope, id) do
  nil -> {:noreply, put_flash(socket, :error, "Not found") |> push_navigate(to: ~p"/company/jobs")}
  job -> {:noreply, assign(socket, :job_posting, job)}
end
```

## Routes

`/dev`: Storybook, LiveDashboard, mailbox. Public: landing/login. Authenticated, Admin: HTTP Basic. `Application.compile_env/2` for env-conditional (NOT `Mix.env()` — unavailable in releases). File extensions via binary pattern-matching plugs.

## Code Organization

- Cross-context schemas: alias context, prefix (`Accounts.User`)
- Verified routes: `~p"/images/logo.svg"`
- Embedded schemas for form validation
- Email composition → mailer modules
- Count fns share query builder with list fns
- `use` → `import` → `require` → `alias`

## DB & Caching

Cache-first MANDATORY: check cache BEFORE DB. DB-first caching → blocking review issue.

```elixir
case ContentCache.get_cached_content(:single, id) do
  {:hit, cached} -> serve_content(conn, cached)
  :miss -> handle_cache_miss(conn, id)
end
```

Seeds: schema change → `seeds.exs` update. Test: `mix run priv/repo/seeds.exs`.

## Fail-Fast Config

Required env var in prod: `System.get_env("VAR") || raise "missing VAR"`. Compile-time missing → fix `runtime.exs` (canonical).

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

## Misc

- Explicit helpers over virtual fields
- Only support formats you actually send
- Security ignores in `.sobelow-conf`, not inline
- Custom static dirs in `static_paths/0` (backend_web.ex)
- GenServer debounce: `Process.send_after` + cancel-and-reset. `Task.Supervisor.start_child` (not `Task.start`) for test stub propagation.
- Coveralls `# coveralls-ignore-start/stop` pragmas inside `case` arm bodies are formatter-accepted — `mix format` does not reindent them.

## Compile-Time Config

❌ `@env Application.compile_env(:app, :env)` + `if @env == :prod` — env comparison leaks infrastructure concern into logic, triggers dialyzer `exact_compare` in non-prod builds.

✅ Named boolean flag per feature/behavior:

```elixir
# config/config.exs
config :myapp, :notify_owner_on_tls_alert, false

# config/prod.exs
config :myapp, :notify_owner_on_tls_alert, true

# lib/myapp/module.ex
@notify_owner Application.compile_env(:myapp, :notify_owner_on_tls_alert, false)
```

- One flag per behavior — readable, testable, no env leakage
- Dialyzer: in non-prod `@notify_owner` is `false` → same `exact_compare` warning → use `@dialyzer {:nowarn_function, fn: arity}` above the function
- Default `false` in `config.exs` so missing config is safe

## See Recipes

UI: `phoenix-component-attribute-ordering`, `phoenix-dropdown-blur`, `phoenix-modal-js-animations`, `phoenix-file-upload-html-labels`, `phoenix-live-title-page-titles`, `phoenix-storybook-setup`.

Elixir: `elixir-with-for-chained-failable-ops`, `elixir-module-organization-skeleton`, `elixir-type-duplication`, `oban-worker-return-contract`, `tidewave-mcp-verification`.
