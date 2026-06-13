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

**Scoped query + `Enum.drop(-1)` interaction**: When converting an unscoped history query to app-scoped, remove any `Enum.drop(-1)` that was dropping the most-recent (last) item from an unscoped result. In unscoped context, the current inbound message (inserted pre-detection) appears last in the result, so drop removes it. In app-scoped context, the inbound message has `app_id: nil` and is naturally excluded by `WHERE col = ^app_id` (PostgreSQL `NULL ≠ value` → false → row drops), so the drop now removes a real history entry instead. Fix: remove the drop, adjust the limit from `11` → `10` (no needless over-fetch), and update the comment to explain why no drop is needed.

**PostgreSQL `col = value` semantics for NULL**: `WHERE col = value` returns false when `col` is NULL, regardless of `value`. For data models where NULL is a meaningful state (e.g., `app_id: nil` for pre-classification rows), the `= ^scoped_id` filter is nil-safe — nil-app rows are automatically excluded without needing an explicit `IS NOT NULL` guard. This is by design, not a corner case. No additional filter is needed; the natural NULL-exclusion is correct.

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
- `phx-change`/`phx-keyup`/`phx-submit` require a `<form>` ancestor — inputs outside a `<form>` silently no-op with NO console error; wrap event-handling inputs in `<.form>` or a bare `<form>` tag
- `live_render` of a child LiveView MUST set `layout: false` to avoid double-layout render; the routed root LiveView owns the layout
- Autofocus-on-open: `<input phx-mounted={JS.focus()} />` — use for keyboard-first overlays/modals so the caret lands without a click

## Dead-Render Placeholders

**Mount runs twice**: `mount/3` → `handle_params/3` run on dead render (`connected?==false`), then again on WS connect (`connected?==true`). Unguarded DB loads execute both times.

Guard each load behind `connected?(socket)`. On dead render, assign placeholders (empty lists, zero counts, safe defaults) for all keys the template references. Stream placeholders MUST call `stream(socket, :key, [], reset: true)` even when skipping the load — LiveView raises `KeyError` on stream reference without `stream/3` init. Hooks (`on_mount`) count as setters: if `on_mount` initializes `:foo`, the LiveView's dead-render branch does NOT need to re-assign `:foo`.

```elixir
# ❌ Dead render will KeyError on @streams.comments (never initialized)
def handle_params(_params, _uri, socket) do
  if connected?(socket) do
    {:noreply, assign_comments(socket, drop)}
  else
    {:noreply, socket}  # ← @streams.comments undefined
  end
end

# ✅ Stream initialized on both paths, comments data guarded behind connected?
def handle_params(_params, _uri, socket) do
  if connected?(socket) do
    {:noreply, assign_comments(socket, drop)}
  else
    {:noreply, socket |> stream(:comments, [], reset: true) |> assign(:comment_count, 0)}
  end
end
```

## then/2 for Conditional Pipelines

`then/2` is the clean pattern for conditional branching at the tail of a `|>` pipeline in `mount/3` or `handle_params/3`. Avoids rebinding the socket or intermediate variables when the condition is a boolean branch.

```elixir
# ❌ Breaks pipeline; Credo VariableReDeclaration (double socket= binding)
socket = socket |> assign(:search_query, query) |> update_search_filters(q)
socket = if connected?(socket) do ... else ... end

# ✅ Single binding; condition is a pipeline step; rename inner param to avoid shadowing
socket =
  socket
  |> assign(:search_query, query)
  |> update_search_filters(q)
  |> then(fn s ->
    if connected?(s) do
      assign_drops(s)
    else
      s |> stream(:drops, [], reset: true) |> assign(:drops_empty?, true)
    end
  end)
```

## Test Discipline

`Application.put_env` is process-global → mutating it from `async: true` ExUnit tests races with any other async test reading the same key, even when Mox stubs are process-local. Fix: split offenders into a sibling `async: false` module in the same file (e.g., `ChannelsTest` alongside `ChannelsSyncTest`). When splitting, verify ALL env-mutating tests migrate to the serial block — partial migration leaves races intact. Also guard with `System.put_env` mutations: they mutate the OS-level `environ`, not the Erlang app config — any async test + concurrent subprocess call races via PATH / HOME / env reads.

`async: false` + `Sandbox.start_owner!(shared: true)` flips the GLOBAL sandbox connection mode, causing concurrent `async: true` tests to route through the shared connection → `40P01 deadlock`. Fix: `@moduletag :no_shared_sandbox` + DataCase guard that skips `shared: true` for serial modules that don't need cross-test isolation (e.g., filesystem-only tests with no DB writes). **Critical**: `async: false` does NOT prevent async tests from running concurrently — it only serializes within the serial queue. Squatting a shared filesystem path (e.g., `partci55/user_files`) still races with any async test touching that path. Isolate filesystem mutations via `Application.put_env(:combobulate, :user_files_dir, System.tmp_dir!())` to force the test to use a unique path.

ExUnit **does NOT** inject `:async => false` into the tags map for `async: false` modules — tag absent → `tags[:async]` = `nil` → `not nil` = `ArgumentError`. Always use `tags[:key] != true` (or `!!tags[:key]`) when checking optional boolean tags. Never use `not tags[:key]`.

**Concurrent async: true tests on fixed filesystem paths**: Tests that mutate a non-unique shared path (e.g., `/tmp/combobulate_llm_latest`, a symlink or directory squatted by multiple tests) MUST be moved to a sibling `async: false` module, even if the path is under `/tmp/`. Unique-per-test directories (via `:erlang.unique_integer`, `System.tmp_dir!()`, or similar) are race-free and safe for `async: true`. Fixed paths are shared state — concurrent setup/teardown overlaps and causes `File.LinkError` or similar. Cure: split `do_write_outcome_jsonl!/3` style describe blocks into a separate `async: false` module; other describe blocks using per-test unique dirs stay async.

**Credo module layout order** (StrictModuleLayout): default is `use` → `import` → `require` → `alias` → module attributes (`@moduletag`). Projects commonly override this order in `.credo.exs` — always check the project's config before flagging violations. `require Logger` must precede `@behaviour` declaration (both are module-level directives; `require` is structural, `@behaviour` is an attribute). Inserting `@moduletag` between `use` and `import`/`alias` triggers two separate violations. Always place module tags after ALL imports, requires, and aliases.

**`require Logger` is NOT implied by `use GenServer`**: even in GenServer modules, `require Logger` must be explicitly added to use Logger macros (e.g., `Logger.info`, `Logger.warning`). The `use` directive does not transitively require Logger. Add `require Logger` in the require block, respecting the module layout order.

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

**Concurrency: `async: false` does NOT stop `async: true` tests from running concurrently**: The `async: false` flag only serializes tests WITHIN the serial queue — it does NOT prevent `async: true` tests in OTHER files from running concurrently with it. When `async: true` tests mutate a global `Application.env` key (credentials like `:telegram_bot_token`, req-option seams like `:bunny_probes_req_options`, or host overrides like `:platform_host`), those mutations race with `async: false` tests reading those same keys, causing concurrent fetches to see `nil` or stale values. **Fix: move ALL env-mutating tests into `async: false` modules**, not just some of them. Partial migration leaves races intact. Example: if `probes_test.exs` mutates `:telegram_bot_token` in `async: true` describe blocks, flip the entire module to `async: false` — every describe block in it touches a global key, so serialization is needed for correctness.

**`System.cmd/3` env semantics**: `env: []` passes an EMPTY environment to the child process — it does NOT inherit the caller's OS env. Subprocesses run shell scripts like `#!/usr/bin/env bash` which depend on PATH. Fix: use `env: prod_env([])` (or a computed clean env dict) to explicitly construct and pass a release-safe PATH. Never use `env: []` for subprocesses that run shell scripts — results in "env: bash: No such file or directory" when concurrent tests have mutated the caller's PATH via `System.put_env`.

**ExCoveralls marker instrumentation semantics**: `# coveralls-ignore-*` directives are applied at INSTRUMENTATION time (during `mix compile`), not at report-render time. If a `.coverdata` artifact exists from a prior compile that predates marker additions, the report reflects the unannotated version — adding markers to source has no effect on stale artifacts. Critical workflow: after adding or modifying any `# coveralls-ignore-*` annotations in source, delete the stale artifacts (`rm -f cover/*.coverdata cover/excoveralls.json`) before re-running the gate. The next gate run recompiles with markers active, regenerates fresh `.coverdata`, and re-renders `excoveralls.json` — the annotated lines flip from `0` (missed) to `null` (ignored) and floor coverage jumps accordingly. Diagnosis: compare `cover/excoveralls.json` timestamp (generated at gate time) vs source file mtime (when markers were added); if JSON predates the edits, it's stale.

**Application.put_env in async: false with on_exit**: When a `async: false` test module mutates `Application.put_env(:app, :key, value)` and calls `Application.put_env(:app, :key, old_value)` or `Application.restore_env(:app, :key)` in `on_exit`, the LIFO execution order of `on_exit` callbacks creates a race: cleanup from test N fires after setup of test N+1 is already running → setup captures the leaked value early, cleanup restores the stale value late, production code runs with the reversed mismatch. Fix: use `Application.delete_env(:app, :key)` in `on_exit` (idempotent, does not re-set a stale value), and establish a fresh default or per-test value via module-level `setup` block that runs before each test. Pairs module-level `setup` (sets) + test-level `on_exit` (deletes), with no restore. Also guard filesystem mutations: use isolated unique paths (e.g., `System.tmp_dir!()`) per test rather than shared, so cleanup from one test does not squat a dir another test is writing to.

**`write_with_retry!` ENOENT retry pattern for concurrent test races**: A private file-write fn can harden itself against concurrent directory deletion (TOCTOU: dir exists at `ensure_dir!` time but deleted before `File.write!`) by catching `:enoent` in a rescue block, re-running `ensure_dir!` once, and retrying the write. Bounded single retry — do NOT loop. This makes production code robust against ANY concurrent dir deletion without changing test code. Shape: `defp write_with_retry!(dir, path, binary) do File.write!(path, binary) rescue e in File.Error -> if e.reason == :enoent do ensure_dir!(dir); File.write!(path, binary) else reraise e, __STACKTRACE__ end end`. The rescue body (retry arm) is a TOCTOU defensive guard — sub-millisecond race window, not deterministically triggerable in tests → appropriate for `coveralls-ignore-start/stop` annotation.

**GenServer + async Task write races (FSM guard + fetch-fresh pattern)**: When a GenServer has async Task paths (spawned via `Task.Supervisor.start_child/2`) that mutate shared DB state, an explicit FSM guard (validating state transitions) alone does NOT eliminate the race — the Task still sees stale in-memory struct. Required companion: **fetch-fresh pattern** — re-read the entity from DB inside the async Task BEFORE applying the transition. Example: `ProcessManager.do_idle_shutdown/1` (async Task) must call `Apps.get_app(app.id)` first; use the fresh `fresh_app` in the Lifecycle transition guard. If `fresh_app` status makes the transition illegal, log and return early. This pattern is in-Task only (unlike the FSM guard which wraps all call sites); it hardens async paths specifically. Severity: guard violations are detectable (not silent), and fresh-read catches them before DB write. Complement: FSM logic (transition table) ensures the guard is consistently applied; fetch-fresh ensures Task execution sees current state, not stale in-memory snapshot.

**Partition-concurrency flakes from real subprocess calls (`:epipe` crashes)**: Under partition load (6 concurrent test processes), `async: true` tests that run real subprocess calls (e.g., `git rev-parse`) can fail with `:epipe` ("shell port crashed after 3 retries") from macOS fork/pipe pressure during high concurrency. This is NOT a logic bug — the test is overspecifying by running a real subprocess just to satisfy an assertion. **Fix**: inject a per-call function seam at the subprocess boundary (NOT module-level Application env, which forces `async: false`) so tests can stub the subprocess away. Example: when a test stubs `:merge_fun` but then runs real `Git.rev_parse/2` calls to satisfy a post-merge equality check, inject a `rev_parse_fun` opt (defaulting to `&Git.rev_parse/2`) so tests can stub both. Result: zero real subprocess calls, deterministic under partition load, stays `async: true`. Rejected alternatives: (a) `async: false` does NOT stop OTHER async tests from generating fork pressure, so it does not eliminate the surface; (b) `:muontrap_module` is process-global and forces the whole module serial; (c) per-call seams are surgical and preserve `async: true`.

**Test seam layer alignment (Rule J)**: Seams should be injected at the SAME layer as the assertion that needs them. Classic omission: stubbing `:merge_fun` but not the two `Git.rev_parse` calls that follow — the `assert_branches_equal/2` check depends on those calls returning matching SHAs, but one seam is missing, leaving a real-subprocess gap right between two stubbed boundaries. Symptom: test passes in isolation (no fork pressure), fails under partition load (`:epipe`). Fix: inject `:rev_parse_fun` alongside `:merge_fun` so the entire assertion boundary is stubbed. Applies to any assertion-seam pair: if code A asserts a property dependent on code B, and code B is stubable, then code B should be stubbed for that test.

## Misc

- **Logger metadata key registration**: Structured logging keys added via `Logger.metadata([key: val])` or conn assigns must be registered in `config :logger, :default_formatter, metadata: [...]` (alphabetical order) or Credo warns. Pattern: add new key to the config array at the same time as the logging site.
- **Nil-safe nested access via `get_in` + `Access.key`**: Extract nested struct+map paths safely with `get_in(struct, [Access.key(:struct_field), "map_key"])` — returns `nil` on struct fields missing AND plain map keys absent, never raises. Useful for parsing API responses (e.g., Stripe metadata) where the path may be partially populated. Pattern: use string keys for API-returned maps (e.g., `metadata["app_id"]`), atom keys for internal maps.
- Explicit helpers over virtual fields
- Only support formats you actually send
- Security ignores in `.sobelow-conf`, not inline
- Custom static dirs in `static_paths/0` (backend_web.ex)
- GenServer debounce: `Process.send_after` + cancel-and-reset. `Task.Supervisor.start_child` (not `Task.start`) for test stub propagation.
- **Process.put/get for delivery markers in synchronous dispatch chains**: when a synchronous call chain (worker → function → adapter → seam) must communicate a side-effect result from the adapter back to the worker in the same process, `Process.put(:marker_key, result)` + `Process.get(:marker_key)` is a clean seam with zero side effects on non-targeted paths when guarded by identity checks (e.g., `if user_id == special_id`). Critical: reset the marker via `Process.delete(:marker_key)` at the chain start to prevent stale results from prior runs in the same worker process. Never share a `Process` dict key across unrelated call chains — risk of false-positive matches.
- Coveralls `# coveralls-ignore-start/stop` pragmas inside `case` or `cond` arm bodies are formatter-accepted — `mix format` does not reindent them. **Critical distinction**: `# coveralls-ignore-next-line` applies to the line it precedes (pattern line in a `case`/`cond` arm, param line in a multi-line fn head); body expressions sit on the NEXT line and are NOT suppressed. Use `coveralls-ignore-start/stop` wrapping body expressions directly. Erlang's coverage tool marks pattern lines (`nil ->`, `condition ->`), `) do` lines (multi-line fn head), and param lines as 0 even when the arm/fn is called and body is executed — these are tracking artifacts, not real coverage. Annotate the pattern/param line with `# coveralls-ignore-next-line: Erlang coverage false negative — ... not counted despite fn being called` (one line above the false-negative line).

- **TOCTOU rescue blocks not deterministically triggerable**: Rescue blocks guarding sub-millisecond TOCTOU windows (e.g., dir deleted between `ensure_dir!` and `File.write!`) are appropriate for `coveralls-ignore-start/stop` — the race is real in production (concurrent tests) but not deterministically triggerable via a single test case. Stale `.coverdata` artifacts cause newly-annotated lines to still show as 0 (missed) — delete `cover/*.coverdata` + `cover/excoveralls.json` after adding markers so next gate recompiles with them active and regenerates fresh artifacts.

- **Erlang coverage false positives on environment-dependent code**: `System.cmd` may raise before a pattern line is reached (binary missing), causing Erlang to mark the pattern and body as 0 even when the code path is tested in other environments. Annotate such lines with `# coveralls-ignore-next-line: Erlang coverage artifact — System.cmd raise intercepts pattern match` when the arm depends on external binary presence.
- **File operations on directory paths that may have non-dir squatters**: When hardening `mkdir_p!` calls, check one level up. Clear any non-dir at `Path.dirname(path)` BEFORE clearing any non-dir at `path` itself, then let `mkdir_p!` create the chain. Example: `File.mkdir_p!(user_files_dir)` can fail with "not a directory" at an intermediate parent if a concurrent test has briefly replaced that parent with a file. Guard: `parent = Path.dirname(path); File.exists?(parent) and not File.dir?(parent) and File.rm_rf!(parent)` — the `File.exists?` check prevents deletion of real dirs. Mis-configured/nil path → `Path.dirname(nil)` raises before any `rm_rf!` → fail-fast, safe.
- **Orphan family deletion (Rule J parallel case treatment)**: When a rewrite removes the sole production caller of a module (leaving it an orphan whose code is never exercised), the module is only PART of the orphan family. The full family includes: the module itself + its test file + any helper functions in OTHER modules that exist exclusively to serve the orphaned module. Partial deletion (module only, tests only) relocates the coverage gap rather than closing it. Example: deleting `routing_advisor.ex` (removed production caller) requires also deleting `routing_advisor_test.exs` (tests the orphan) AND `DailyStats.cache_hit_ratio_by_harness/2` + `roles_for_chain/1` + the `@chain_to_roles` attr from `daily_stats.ex` (exist only to feed the advisor). Decision tree: (1) identify all symbols with zero production callers post-rewrite, (2) identify all symbols whose sole caller is one of the orphaned symbols, (3) delete the transitive closure together — one pass, no partial. Verify post-edit via Grep for the removed symbols' names; `mix compile --warnings-as-errors` will catch unused types/attrs/aliases. Stale coverage instrumentation artifacts may still reflect the deleted module in the denominator — after deletion, flush `cover/*.coverdata cover/excoveralls.json` before re-running the coverage gate.

- **Default args on single-clause private fns**: Elixir warns "default values for optional arguments never used" when a single-clause `defp` fn has default args but no caller uses the default path. Fix: remove defaults, pass explicit arg at all call sites. Affects `mix compile --warnings-as-errors`.
- **Code complexity limits (Credo)**: ABC size (30) and nesting depth (2) limits trigger on deeply nested `if/else` or `case` inside `case` arm bodies. Fix: extract nested dispatch to a named helper fn (keeps each fn focused). Example: nested `if deploy_fun / if phoenix_app?` inside a `case` arm → extract to `run_deploy/2` private fn with explicit dispatch logic.
- **Nested case → fn clauses**: Replace nested `case` inside `case` arm with separate fn clauses for each result pattern. Eliminates nesting depth and reduces ABC; pass accumulated context as fn args. Example: `do_promote/1` → split inner `case deploy_result` into `handle_deploy_result/3` with clauses for `:ok`, `{:error, _}`.

- **Removing functions + types + module attrs in parallel**: When deleting a function, its `@spec` references one or more custom types (e.g., `@type harness :: atom()`, `@type harness_ratio :: {harness(), Decimal.t()}`). Removing only the function body but not its types leaves unused-type warnings under `--warnings-as-errors`. Cure: in one edit, remove (1) the function's `@doc` + `@spec` + `def` body + any private helper `defp`, (2) the custom `@type` declarations that serve ONLY that function's spec, (3) any module `@attr` (e.g., `@chain_to_roles`) that exclusively feeds the deleted function. Verify post-edit via Grep for each removed symbol's name (`@type harness`, `@chain_to_roles`, etc.) — zero matches confirms clean removal. The companion rule: removal happens in a single pass, not incrementally.
- **Minimal coverage fix for private fns without opts seam**: When a private fn calls an external module with no opts/mock seam to stub, inject a thin `Application.get_env` config key (nil-safe default) inside the private fn. In tests, `Application.put_env` to inject a stub, exercising the private fn without full module setup. Example: `do_promote/1` → read `:preview_deploy_fun` config inside the fn (nil → use real Deploy, non-nil → call stub), avoid Mox on entire module.
- **Public fn calling public fn for internal cleanup**: When a public fn calls another public fn internally (not for its full side-effects but only for cleanup/state-reset), and the called fn later gains new side-effects (e.g., re-pinning a state invariant), the caller must bypass to the private primitive to avoid premature/duplicate effects. Example: `add_preview_route/2` calling `remove_preview_route/1` — when re-pin is added to `remove_preview_route/1`, `add_preview_route/2` must call the private `remove_all_copies/1` instead to avoid re-pinning mid-route-addition.
- **Caddy route ordering**: `POST .../routes/0` prepends, `POST .../routes` (no index) appends. Neither prepend nor a one-time append survives later mutations without re-shadowing. The only order-independent "keep last" guarantee is explicit delete-by-id + append run as the final step of every mutation (not just at boot). Single HTTP server per listen address (Caddy: `listener address repeated` error if >1 server on same port — catch-all 404 must be a terminal route in the existing server, not a separate server). **Caddy composite route ids** — each topology (`phoenix`, `static`, `wake`) has its own `@id: "app-#{slug}-#{kind}"` to prevent duplicate-route bugs on topology switch. `atomic_replace/2` (delete-by-id + append) replaces the old recursive loop pattern. Caddy GET /id/{id} semantics are symmetric to DELETE (200 + route body when present, 404 when absent) — safe for post-delete verification without full route list scan.
- **Path-matching fn clauses vs nested if/else**: When dispatching on HTTP request path (e.g., GET /id/{...} vs other GET), use pattern-matching function clauses with path guards (`"GET", "/id/" <> _rest`) instead of nested if/else inside a single fn body. This avoids Credo nesting-depth violations while keeping path logic localized. Example: `get_response(method, path)` with clauses for `("GET", "/id/" <> _)`, `("GET", _)`, `("POST", _)` separates concerns cleanly.
- **Keyword list alphabetical ordering**: Multi-value keyword lists in dispatcher calls (e.g., `Dispatcher.dispatch(:role, prompt, system_prompt, opts)`) and opts passed through higher-order fns should list keys in alphabetical order for clarity and stable diffs. No Credo enforcement, but convention + readability benefit.
- **`Keyword.put_new` in dispatchers**: A dispatcher using `Keyword.put_new/3` to set defaults (e.g., `model:`, `effort:`, `role:`, `harness:`) allows the caller's supplied values to win. Pass-through opts like `:allowed_tools`, `:user_id`, `:working_dir` that are NOT `put_new`'d ride through unchanged — safe for caller opts to override/add defaults. Useful for opt allowlisting (dispatcher sets a default, caller can override).
- **Module attribute concern separation**: When two module attributes share a value for different reasons (e.g., `@default_client_ip "46.225.1.182"` for Namecheap API ClientIp param vs `@phoenix_origin_ip "46.225.1.182"` for DNS record target), give each its own named constant with explicit comment clarifying the concern. Future changes to one concern (e.g., API param update) must not silently affect the other (DNS target) — independent naming prevents accidental coupling.
- **Prompt-hint + write-target derivation alignment**: When a function branches prompt-hint text (user-visible to LLM) and a data write (e.g., DNS record target) on the same condition, derive the branching value in a shared helper or the same module so structural drift is impossible. Example: `Concierge.dns_instructions_hint/2` and `Namecheap.dns_target_hosts/2` both branch on `get_in(app.infra_manifest || %{}, ["app_type"]) == "phoenix_with_db"` — hint shows the correct domain to user, write targets the correct nameserver, both stay in sync because the condition is data-driven, not hard-coded.
- **Credo inline type-alias rule**: When Credo flags inline `Ecto.UUID.t()` in a `@spec` (e.g., `@spec list_recent(..., app_id: Ecto.UUID.t()) → ...`), introduce a module-level semantic type alias (`@type app_id :: Ecto.UUID.t()`) and use it in the spec instead. Assign each domain concept a named type (not just one per module, but one per semantic concept) so specs are readable and changes are localized. Example: `Messages` context uses `@type user_id` and `@type app_id` even though both are `Ecto.UUID.t()` — naming clarifies the semantic intent at each call site.
- **`@type opts` union syntax for heterogeneous lists**: When a function accepts a keyword list that may contain different key-value patterns (e.g., `list_recent/3` accepts either `[scope: :current_app]` OR `[app_id: uuid]`), the type is intra-list union `[{:app_id, app_id()} | {:scope, :current_app}]`. This describes a single-element heterogeneous list. Dialyzer accepts it, but more accurate is `[{:app_id, app_id()}] | [{:scope, :current_app}]` (union of two separate homogeneous lists), which clarifies that a given call is one or the other, not a mix. Use the union form for precision when call sites use exactly one of the two patterns.

## Test Seams

**Req.Test for HTTP stubs**: `Req.Test.json/2` (not `/3` — there is no 3-arity version) returns a mocked JSON response. For HTTP error responses (non-2xx status), use `Plug.Conn.put_resp_content_type/2` + `Plug.Conn.send_resp/3` directly:

```elixir
Req.Test.stub(MyAdapter, fn conn ->
  conn
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "message"}))
end)
```

Calling code that handles `:error` from the adapter will see `{:error, _}` as expected. This pattern is used in handler tests where the seam is at the `Channels.send/2` level (stubbing the adapter module).

**Multiple `Req.Test.stub/2` calls with distinct plug owners**: When a single test (or module) requires stubs for multiple HTTP endpoints (e.g., an API call via `Bunny` and a separate edge-cache probe via `Deploy`), define separate `Req.Test.stub(PlugOwnerModule, fn conn -> ... end)` stubs keyed by the calling module. Each stub is process-local and independent — no interference between stubs with different `PlugOwnerModule` keys. Example: `Req.Test.stub(Combobulate.Hosting.Bunny, ...)` for purge API + `Req.Test.stub(Combobulate.Builds.Deploy, ...)` for verify probe coexist in the same test.

**`capture_log` does NOT lower the global Logger level**: When test config sets `config :logger, level: :warning`, `ExUnit.CaptureLog.capture_log([level: :info], fn -> ... end)` changes the capture threshold but NOT the global Logger level. `Logger.info/1` remains a no-op at the application level and never emits, so `:info` messages do not appear in the captured log. Fix: test observable behavior (DB state changes, return values) rather than relying on log assertion for suppressed-level messages. Alternative: use `capture_log([level: :debug], ...)` to lower the capture threshold below the global level IF the global level is debug-or-higher in that test context.

**`%Req.Response{}` pattern matching + Req 0.5+ headers format**: Match `%Req.Response{status: 200, headers: headers}` explicitly, not bare `%{status: 200, headers: headers}`. Req 0.5+ wraps headers in `%{"header-name" => ["value"]}` format (map with list-wrapped values, legacy_headers_as_lists: false). When reading headers, handle list-wrapped values: `[value | _rest]` in map clauses, NOT `{name, value}` tuple-list patterns from older Req versions.

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

**Dialyzer `pattern_match_cov` on header-reading functions**: When a function pattern-matches response headers from an HTTP library (e.g., Req 0.5+), the structure may be union-typed or depend on configuration flags. Functions handling headers with multiple clause patterns (e.g., tuple-list clauses + map clauses) may exhibit dead-code warnings (`pattern_match_cov`) if the effective runtime format is narrower than the union type. Fix: keep ONLY the clause matching the actual runtime format. Example: Req 0.5+ with `legacy_headers_as_lists: false` produces `%{"name" => ["value"]}` maps only — remove any tuple-list or bare-string header clauses; the map clause is the sole live path. Verify by running `mix dialyzer` after removing dead clauses.

## Enum & Sigil Patterns

**Credo `ListAppend` — prefer cons over ++ for single-item appends**: Use `[item | list]` or `[{:key, val} | opts]` instead of `list ++ [item]` when appending a single item to a list. The cons pattern is idiomatic Elixir, more efficient, and satisfies Credo `ListAppend` violations. Common in Req option injection: instead of `opts ++ [{:retry, false}]`, use `[{:retry, false} | opts]`.

**`match?/2` for structural testing**: Use `match?({:blocked, _reason}, tunnel)` to test a pattern without binding unused variables. Avoids Credo `UnusedVariableNames` warnings (use `_reason` not bare `_`). Cleaner than `case tunnel do {:blocked, _} -> true; _ -> false end`.

**`~w()` sigil destroys multi-word phrase literals**: `~w(add back)` splits on whitespace and produces `["add", "back"]`, NOT `["add back"]`. For any literal phrase ≥2 words, use explicit list syntax: `["add back", "bring back", "put back"]`. Silent failure: tests may pass if a secondary gate (e.g., subject-token overlap in a matcher) compensates, masking the destructured phrase. Always use `~w()` ONLY for single-word atom lists.

**`Enum.find_value/3` for first-match-wins with default**: Returns first truthy result from the block; nil continues iteration; default fires on exhaustion. Clean pattern for "find the first X that satisfies predicate, or return default":

```elixir
Enum.find_value(candidates, :no_match, fn candidate ->
  if matches_criteria(candidate) do
    {:match, candidate}
  else
    nil  # continue to next
  end
end)
```

**Chained `Enum.reject/2` → merge predicates**: Two separate rejects are a Credo `FilterIntoWith` efficiency warning. Merge into single reject with `or`:

```elixir
# ❌ Chained rejects
rejects = candidates |> Enum.reject(&(&1 in stop_words)) |> Enum.reject(&(byte_size(&1) < 2))

# ✅ Single reject with merged predicate
rejects = Enum.reject(candidates, &(&1 in stop_words or byte_size(&1) < 2))
```

**Cond arm ordering with multi-marker patterns**: In a `cond` with arms matching API response body text (e.g., Namecheap error messages), more-specific patterns (text marker combinations) must precede narrower patterns (single error codes). Example: an arm matching `Status="OK"` wins first; a subsequent multi-marker arm (`"Invalid request IP"` OR `"not whitelisted"`) matches ANY of those text strings; only THEN a separate arm for bare numeric code `2033504` is reached. If you reverse the order, the code-only arm never executes because a test with BOTH markers matches the text-marker arm first. Fix: order cond arms from most-specific (multi-marker) to least-specific (single code), or split into separate branches to prevent shadowing.

**Deterministic token-overlap for semantic matching** (e.g., verifying a request references a subject): normalize request text → check for explicit directive phrase (literal substring OR regex pattern) → strip directive words + articles → verify ≥1 remaining "content" token appears in the candidate subject's token list. Example: "add dark mode back" matches `Revert "Update dark mode"` because (a) contains "add back", (b) after stripping "add"/"back"/"the"/articles, "dark" and "mode" tokens exist in both request and subject. Plain "make the dark mode bigger" → no match (no "add back"/"bring back" directive).

## See Recipes

UI: `phoenix-component-attribute-ordering`, `phoenix-dropdown-blur`, `phoenix-modal-js-animations`, `phoenix-file-upload-html-labels`, `phoenix-live-title-page-titles`, `phoenix-storybook-setup`.

Elixir: `elixir-with-for-chained-failable-ops`, `elixir-module-organization-skeleton`, `elixir-type-duplication`, `oban-worker-return-contract`, `tidewave-mcp-verification`.

## JSON Encoding & Make Recipes

**`Jason.OrderedObject.new/1` for key-order preservation**: When JSON output format specifies field ordering different from alphabetical default, use `Jason.OrderedObject.new/1` with a keyword list. `Jason.encode!/1` respects the insertion order, emitting keys in the order supplied. Example: hook_manifest.json and inspector_settings.json require specific key ordering; pass keyword lists to `OrderedObject.new/1` to preserve output field order.

**Elixir heredoc syntax**: Closing `"""` MUST be on its own line, never inline with content. ❌ `"""content"""` (syntax error). ✅ `"""` / `content` / `"""`. Inline trailing `"""` terminates the heredoc immediately, breaking the parse.

**Make variable escaping**: In Makefile recipes (lines after the target + `:` rule), a literal shell variable reference requires double-`$`. Example: `echo $${VAR:-default}` in a recipe emits `${VAR:-default}` to the shell, allowing shell parameter expansion. Single `$` is Make syntax (refers to Make variable). This is critical for `export OCG_CODEGEN_DIR=$${OCG_CODEGEN_DIR:-/path}` patterns that default env vars in CI/dev-independent shells.

## Orphan-Family Deletions & Generic Dispatchers

When a pitch lists "delete X's phoenix branch", distinguish between phoenix-SPECIFIC functions and generic app-type-parameterized dispatchers. Deleting a single ternary arm from a generic dispatcher (e.g., `Apps.reprovision_idempotent!/2` → `stack = if app_type == "static_site", do: "static", else: "phoenix"`) means churning one parameter for zero behavior change and high test cost. After a code path is retired, the dispatcher's unused branch becomes unreached but the fn is still generic and should be left intact. Examples:

- `Apps.reprovision_idempotent!/2` — generic app-type dispatcher; leave the ternary unchanged even if the phoenix branch is unreachable post-retirement.
- `BuildQuality.cohort_baseline/2` — generic parameterized query (`where r.app_type == ^app_type`); no phoenix-specific logic present.

True phoenix-specific targets for deletion: functions that would NOT exist if the platform only served static sites (e.g., `Deploy.release_dir_for/1`, `Deploy.compile_release/1`, `Rollback.do_phoenix_rollback/6`). Leave generic dispatchers alone; delete only the phoenix-exclusive implementations.

## Test Regression Patterns

When a guard blocks a code path at the enqueue layer (e.g., `if phoenix_app?(app) then refuse else enqueue`), the regression test must prove the guard fires BEFORE the blocked path branches. Two patterns:

1. **Guard-placement test** — prove the guard sits ABOVE the branching cond. Example: when guarding at `enqueue_build/4` top (above the `cond` that checks `rollback_intent?` first), the regression test for rollback interception must assert: (a) refusal reply sent, (b) NO Oban job enqueued, (c) rollback dispatcher NOT called (stub the internal `run_housekeeper` call + `refute_received` macro). Absence of an Oban job alone does NOT prove the guard fired before the rollback branch; the stub + refute-received confirms the dispatcher was not reached.

2. **Credo VariableRebinding** — when building test setup with repeated bindings (e.g., `{:ok, app1} = ... ; {:ok, app2} = ...`), use distinct variable names (`base_app`, `ambiguous_app`) rather than re-binding the same name twice. Credo detects double-binding as a violation even within the same test; fix by renaming to clarify test intent (each case sets up a different app variant).

Double-binding in tests is semantically allowed but signals test-code sloppiness; always use distinct names to improve readability and pass Credo `VariableRebinding` checks.
