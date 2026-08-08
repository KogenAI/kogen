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

- Add or update a dep → run `codegen-document <dep_name>` to (re)generate its usage_rules doc at the new locked version.
- Only proper Elixir fns that exist
- `@spec` on public fns ONLY — NEVER on `defp`
- Struct type: `@type t :: %__MODULE__{}` — never include keys
- `@impl` fns don't need `@spec`
- ALWAYS `@impl Module.Name` not `@impl true`
- `Ecto.Enum` for dropdown fields
- Type 2+ times in `@spec` → extract `@type` at module top
- **Credo TypeDuplication**: `String.t()` appearing 2+ times in the same `@spec` fires Credo duplication. FIX: extract `@type ms_string :: String.t()` at module top, use alias in `@spec`. Applies to any semantic type appearing 2+ times.
- **Credo ABC/Complexity**: (a) `cond do` with 7+ arms reliably exceeds Credo ABC (30) and cyclomatic (9). Extract each arm's logic to a private `check_*!/1` helper. (b) Sequential `if raise` blocks accumulate ABC score — extract each guard condition to a named private `check_*!/1` helper instead. Both patterns restore clean scoring.
- NEVER `any()` — research types in `deps/`
- Return-type change or new branches → update `@spec`, run `mix dialyzer`
- **Multi-clause default-arg compile error fix**: When a function needs default args across multiple clauses (e.g., pattern-matching on atom tags), use a SINGLE function head carrying the default plus bare delegating clauses. Example: `def parse_per_role(output, harness, opts \\ [])` head, followed by `def parse_per_role(_output, :other, _opts), do: %{}` and `def parse_per_role(output, :claude, opts) do ... end`. Elixir requires the default `\\` on only the FIRST clause; placing it on multiple clauses is a compile error. The single-head + delegate form avoids it.

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
- **`with [head | _] <- list` for graceful-fail patterns**: Use destructuring in `with` guards to handle both empty lists and non-binary values uniformly via a single `else _ -> %{}` clause. Example: `with [subagents_dir | _] <- locate_subagents_dir(...) do ... else _ -> %{} end` returns `%{}` whether the list is empty (no `[head | _]` match) or `locate_subagents_dir` returns a non-list (also no match). This is cleaner than separate guards and consolidates all failure paths.
- Grep fn usage before modifying/removing. Removing features: remove ALL related code, imports, tests.
- **Duplicate boolean logic → shared helper**: When two modules must use identical enable/disable logic (e.g., both static.ex and channel.ex check `enabled?`), extract to a shared `Utils` or named module helper — copy-paste logic in two files is a latent divergence bug. The shared computation becomes the single source of truth and prevents subtle inconsistencies when one caller later updates their copy.
- **GenServer.call/3 timeout exit shape**: `GenServer.call/3` timeout exits as `{:timeout, {mod, fun, args}}`, never the bare atom `:timeout`. A `try/catch` arm like `catch :exit, :timeout` is always dead code. Use bare `case` on function return values or pattern-match on the full `{:timeout, ...}` tuple in exception handlers.
- **Oban plugin `max_age` unit trap**: `Oban.Plugins.Lifeline.rescue_after` takes MILLISECONDS (e.g., `:timer.hours(2)` from `:timer` module). `Oban.Plugins.Pruner.max_age` takes SECONDS as a bare integer. Reusing `:timer.hours/1` in Pruner config makes retention 1000× too long. Always use the bare integer literal for Pruner: `max_age: 604_800` (7 days), never `:timer.hours(168)`.

`_core.md` § then/2 for Conditional Pipelines covers the Credo `VariableRebinding` double-binding fix.

**Event Handlers Must WIRE The Action, Not Just Display It.**
A handler (`handle_event`, `handle_call`, `handle_cast`, `handle_info`) that puts the system into a new VISIBLE state MUST also invoke the work that PRODUCES it. Anti-patterns: a reconcile/loader that fills a `queue` assign but never calls start-next; a `draft` handler that only `File.write`s and closes; a `build` handler that only `Logger.info`s. When the criterion is "X happens," grep the handler for the `start`/`spawn`/`run`/`enqueue` that MAKES X happen, not just the assign that SHOWS X. Pair every "shows state Y" with a test asserting the SIDE EFFECT (process started, file written, message sent), not just the rendered label. Applies to backend GenServers and frontend LiveViews alike.

**File-Listing Scans — Filter By Extension.**
A scan that treats every file in a directory as a domain object picks up strays (`.html` mock, `.DS_Store`, swapfile). Filter to the expected extension (`String.ends_with?(&1, ".md")` / `Path.extname/1`) and skip the rest silently.

## Cleanup

Remove generator file → check source first:

```bash
grep -r "PageController" lib/my_app_web/router.ex || echo "No routes, safe to delete"
```

Never `rm -rf _build`. Target specific files.

## Hot Reload

`.ex`, `.heex`, JS/CSS, migrations, test files — auto. Restart required: `config/*.exs`, Oban workers, GenServer/Supervisor, mix.exs.
