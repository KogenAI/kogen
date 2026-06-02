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

## Env Var Reading

`System.get_env` ONLY in `config/` (mostly `runtime.exs`). NEVER in `lib/` app code.
Read config via `Application.get_env/3` (runtime) or `Application.compile_env/2` (compile-time).
Why: env read once at boot → efficient; all env vars greppable in one dir; missing-var fail-fast lives in `runtime.exs` `required_env`, not scattered downstream.

- ❌ `lib/.../foo.ex`: `System.get_env("STRIPE_WEBHOOK_SECRET") || ""` — silent-empty, ungreppable, no boot fail-fast
- ✅ `runtime.exs`: add to `required_env.(~w(... STRIPE_WEBHOOK_SECRET))` → `config :app, :stripe_webhook_secret, required["..."]`; `lib/` reads `Application.fetch_env!(:app, :stripe_webhook_secret)`

## Asset Bundling

Vite/esbuild configs must include asset hash markers in output filenames (e.g., `/assets/index-HASH.js`). Detection pattern in build tools should distinguish between source imports (`/src/main.jsx`) and built assets using the hash discriminator `\.\w+\.js` (hashed segment). Example:

- ❌ Source shape: `<script src="/src/main.jsx"></script>` (no build output)
- ✅ Built shape: `<script src="/assets/index-a1b2c3d4.js"></script>` (hash present)

Regex: `\.\w+\.` matches the hash dot-sep-dot pattern; use as gate to fall through to build step if absent.

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

## Test Discipline

`Application.put_env` is process-global → mutating it from `async: true` ExUnit tests races with any other async test reading the same key, even when Mox stubs are process-local. Fix: split offenders into a sibling `async: false` module in the same file (e.g., `ChannelsTest` alongside `ChannelsSyncTest`). When splitting, verify ALL env-mutating tests migrate to the serial block — partial migration leaves races intact.

`async: false` + `Sandbox.start_owner!(shared: true)` flips the GLOBAL sandbox connection mode, causing concurrent `async: true` tests to route through the shared connection → `40P01 deadlock`. Fix: `@moduletag :no_shared_sandbox` + DataCase guard that skips `shared: true` for serial modules that don't need cross-test isolation (e.g., filesystem-only tests with no DB writes).

ExUnit **does NOT** inject `:async => false` into the tags map for `async: false` modules — tag absent → `tags[:async]` = `nil` → `not nil` = `ArgumentError`. Always use `tags[:key] != true` (or `!!tags[:key]`) when checking optional boolean tags. Never use `not tags[:key]`.

Example pattern (channels_test.exs):

```elixir
# Tests that mutate Application env or run serially without needing shared sandbox
defmodule ChannelsSyncTest do
  use ExUnit.Case, async: false
  @moduletag :no_shared_sandbox  # Opt out of shared sandbox; safe for FS-only tests

  setup do
    # Application.put_env(...) safe here; no DB deadlock risk
  end

  test "send_to_owner handles no_owner_configured" do
    # ...
  end
end

defmodule ChannelsTest do
  use ExUnit.Case, async: true
  # Safe for async — does not mutate Application env
end
```

## Misc

- Explicit helpers over virtual fields
- Only support formats you actually send
- Security ignores in `.sobelow-conf`, not inline
- Custom static dirs in `static_paths/0` (backend_web.ex)
- GenServer debounce: `Process.send_after` + cancel-and-reset. `Task.Supervisor.start_child` (not `Task.start`) for test stub propagation.
- Coveralls `# coveralls-ignore-start/stop` pragmas inside `case` arm bodies are formatter-accepted — `mix format` does not reindent them.
- **Default args on single-clause private fns**: Elixir warns "default values for optional arguments never used" when a single-clause `defp` fn has default args but no caller uses the default path. Fix: remove defaults, pass explicit arg at all call sites. Affects `mix compile --warnings-as-errors`.
- **Code complexity limits (Credo)**: ABC size (30) and nesting depth (2) limits trigger on deeply nested `if/else` or `case` inside `case` arm bodies. Fix: extract nested dispatch to a named helper fn (keeps each fn focused). Example: nested `if deploy_fun / if phoenix_app?` inside a `case` arm → extract to `run_deploy/2` private fn with explicit dispatch logic.
- **Nested case → fn clauses**: Replace nested `case` inside `case` arm with separate fn clauses for each result pattern. Eliminates nesting depth and reduces ABC; pass accumulated context as fn args. Example: `do_promote/1` → split inner `case deploy_result` into `handle_deploy_result/3` with clauses for `:ok`, `{:error, _}`.
- **Minimal coverage fix for private fns without opts seam**: When a private fn calls an external module with no opts/mock seam to stub, inject a thin `Application.get_env` config key (nil-safe default) inside the private fn. In tests, `Application.put_env` to inject a stub, exercising the private fn without full module setup. Example: `do_promote/1` → read `:preview_deploy_fun` config inside the fn (nil → use real Deploy, non-nil → call stub), avoid Mox on entire module.
- **Public fn calling public fn for internal cleanup**: When a public fn calls another public fn internally (not for its full side-effects but only for cleanup/state-reset), and the called fn later gains new side-effects (e.g., re-pinning a state invariant), the caller must bypass to the private primitive to avoid premature/duplicate effects. Example: `add_preview_route/2` calling `remove_preview_route/1` — when re-pin is added to `remove_preview_route/1`, `add_preview_route/2` must call the private `remove_all_copies/1` instead to avoid re-pinning mid-route-addition.
- **Caddy route ordering**: `POST .../routes/0` prepends, `POST .../routes` (no index) appends. Neither prepend nor a one-time append survives later mutations without re-shadowing. The only order-independent "keep last" guarantee is explicit delete-by-id + append run as the final step of every mutation (not just at boot). Single HTTP server per listen address (Caddy: `listener address repeated` error if >1 server on same port — catch-all 404 must be a terminal route in the existing server, not a separate server).

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
