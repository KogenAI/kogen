# Developer — Phoenix

## Pre-Completion Greps

```bash
grep -rn "@impl true" lib/ | grep -v "_test"    # → @impl ModuleName
grep -rn "{:ok, _} =" lib/ | grep -v "_test"    # → case, not bare match
```

After schema/migration change:

```bash
mix ecto.migrate && mix ecto.rollback && mix ecto.migrate   # reversibility
mix format
mix compile --warnings-as-errors
mix credo --strict
```

Then targeted test file(s). Dead modules → Credo warnings → wire via `grep -r "MyNewModule" lib/ test/`.

## Elixir Codegen Rules

- Only proper Elixir fns that exist
- `@spec` on public fns ONLY — NEVER on `defp`
- Struct type: `@type t :: %__MODULE__{}` — never include keys
- `@impl` fns don't need `@spec`
- ALWAYS `@impl Module.Name` not `@impl true`
- `Ecto.Enum` for dropdown fields
- Type 2+ times in `@spec` → extract `@type` at module top
- NEVER `any()` — research types in `deps/`
- Return-type change or new branches → update `@spec`, run `mix dialyzer`

## Code Patterns

- No catch-all fallback — fail fast
- Always alias used modules
- Never wrapper fns that just call another fn
- `if/else` for booleans, not `case true/false`
- `{:ok, value}` / `{:error, reason}` tagged tuples
- `rescue` without explicit `try`
- ❌ Default runtime env var to dev-machine path. Require via `required_env.(...)` in `:prod`.
- Alphabetical: map keys, struct keys, assigns, schema fields, attrs, env vars
- Prefix unused: `_var`
- Each `|>` own line, raw value start
- NEVER single-fn pipelines: `v |> Fn()` ❌ → `Fn(v)` ✅
- `case` over nested `if`. `with` for 3+ chained failable ops.
- Grep fn usage before modifying/removing. Removing features: remove ALL related code, imports, tests.

## Cleanup

Remove generator file → check source first:

```bash
grep -r "PageController" lib/my_app_web/router.ex || echo "No routes, safe to delete"
```

Never `rm -rf _build`. Target specific files.

## Hot Reload

`.ex`, `.heex`, JS/CSS, migrations, test files — auto. Restart required: `config/*.exs`, Oban workers, GenServer/Supervisor, mix.exs.

## Pitfall — LazyHTML

First LiveView test using `render_change`/`render_click`/`element` → `Protocol.UndefinedError: protocol Enumerable not implemented for LazyHTML`. Fix:

```bash
MIX_ENV=test mix deps.compile --force lazy_html phoenix_live_view && MIX_ENV=test mix compile --force
```
