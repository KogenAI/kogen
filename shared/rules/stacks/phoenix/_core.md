# Phoenix / Elixir — Core

Cross-role facts. Idioms, Ecto, contexts.

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

- Cross-context schemas: alias context, prefix (`Accounts.User`). Verified routes: `~p"/images/logo.svg"`.
- Embedded schemas for form validation. Email composition → mailer modules.
- Count fns share query builder with list fns. `use` → `import` → `require` → `alias`.

## DB & Caching

Cache-first MANDATORY: check cache BEFORE DB. DB-first caching → blocking review issue.

```elixir
case ContentCache.get_cached_content(:single, id) do
  {:hit, cached} -> serve_content(conn, cached)
  :miss -> handle_cache_miss(conn, id)
end
```

Seeds: schema change → `seeds.exs` update. PostgreSQL `col = value` returns false when `col` is NULL — nil-app rows auto-excluded by `= ^scoped_id`, no explicit `IS NOT NULL` guard needed.

## Fail-Fast Config

Required env var in prod: `System.get_env("VAR") || raise "missing VAR"`. Compile-time missing → fix `runtime.exs`.

## Env Var Reading

`System.get_env` ONLY in `config/` (mostly `runtime.exs`). NEVER in `lib/` app code. Read config via `Application.get_env/3` (runtime) or `Application.compile_env/2` (compile-time).

- ❌ `lib/.../foo.ex`: `System.get_env("SECRET") || ""` — silent-empty, ungreppable
- ✅ `runtime.exs`: add to `required_env.(~w(... SECRET))` → `config :app, :secret, required["..."]`; `lib/` reads `Application.fetch_env!(:app, :secret)`

## then/2 for Conditional Pipelines

`then/2` for conditional branching at pipeline tail — avoids Credo `VariableReDeclaration` from double socket-binding.

```elixir
socket =
  socket
  |> assign(:search_query, query)
  |> then(fn s ->
    if connected?(s) do assign_drops(s)
    else s |> stream(:drops, [], reset: true) |> assign(:drops_empty?, true)
    end
  end)
```

## Compile-Time Config

❌ `@env Application.compile_env(:app, :env)` + `if @env == :prod` — leaks infra concern, triggers dialyzer.

✅ Named boolean flag per feature: `config :myapp, :notify_on_alert, false` (prod.exs: `true`); `@flag Application.compile_env(:myapp, :notify_on_alert, false)`. One flag per behavior; use `@dialyzer {:nowarn_function, fn: arity}` on both caller + callee for test-gate patterns.

## Credo Rules (one-liners)

- `PrivateFunctionSpec`: `@spec` on `defp` → remove. Specs on public fns only.
- `UnusedType`: `@type` not in any `@spec` → remove.
- `TypeDuplication`: type used 2+ times → extract named `@type` alias.
- `ListAppend`: `list ++ [item]` → `[item | list]` (cons idiom).
- `SinglePipe/FilterIntoWith`: `from(...) |> Repo.one()` → assign query variable, then `Repo.one(query)`.
- `StrictModuleLayout`: `use` → `import` → `require` → `alias`. `require Logger` before `@behaviour`.
- `~w()` sigil: splits on whitespace — NEVER for multi-word phrases. Use `["add back", ...]` lists.
- `match?/2`: use `match?({:blocked, _reason}, val)` for structural tests without binding unused vars.
- Chained `Enum.reject/2` → merge: `Enum.reject(list, &(&1 in stops or byte_size(&1) < 2))`.
- `IO.puts` → `IO.write(:stdio, msg <> "\n")` (Credo `NoIO.puts`).
- Stale `.beam` artifact: single-file credo clean, full-project fails → `mix clean` then re-run.

## Test Discipline

- `async: true` default. `Application.put_env` is process-global → move ALL env-mutating tests to `async: false` sibling module. Partial migration leaves races intact.
- `async: false` does NOT stop `async: true` tests from running concurrently — move ALL callers of shared global keys.
- `tags[:key] != true` (never `not tags[:key]` — ExUnit doesn't inject `:async => false` into tag map).
- `System.cmd/3` `env: []` passes EMPTY env — subprocesses needing PATH get `:enoent`. Pass explicit env.
- coveralls markers applied at INSTRUMENTATION time — delete stale `cover/*.coverdata` after adding markers.
- `on_exit` runs in `OnExitHandler` process; `self()` ≠ test PID. Use `Application.delete_env/2` in on_exit, not restore.
- For async Task paths in GenServer: FSM guard + fetch-fresh pattern (re-read from DB before applying transition).
- Inject per-call fn seam at subprocess boundary (not module-level Application env) to stay `async: true`.

## Test Seams

`Req.Test.json/2` (not `/3`) for mocked JSON responses. HTTP error responses:

```elixir
Req.Test.stub(MyAdapter, fn conn ->
  conn
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "message"}))
end)
```

Req 0.5+ headers: `%{"header-name" => ["value"]}` format (list-wrapped values, not tuple-list).

## See Recipes

UI: `phoenix-component-attribute-ordering`, `phoenix-dropdown-blur`, `phoenix-modal-js-animations`, `phoenix-file-upload-html-labels`, `phoenix-live-title-page-titles`, `phoenix-storybook-setup`.

Elixir: `elixir-with-for-chained-failable-ops`, `elixir-module-organization-skeleton`, `elixir-type-duplication`, `oban-worker-return-contract`, `tidewave-mcp-verification`.
