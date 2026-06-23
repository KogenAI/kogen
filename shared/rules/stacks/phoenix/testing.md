# Testing — Phoenix / Elixir

## Sanctioned Commands

| Role                 | Allowed                                                                                     |
| -------------------- | ------------------------------------------------------------------------------------------- |
| developer-phoenix-\* | `mix test test/specific_test.exs` (single, no `--cover`); `:42`; `--trace path/to/file.exs` |
| reviewer-phoenix     | none                                                                                        |
| Gate (auto)          | `make ci`, `make llm`, `make llm-phoenix`                                                   |

`--trace` sets `--max-cases 1`, disables timeouts. Dev MUST NOT run `make ci`, bare `mix test`, `--cover`/`coveralls`. Zero Credo warnings, zero failures.

## Asset Paths in Phoenix 1.8.x — Nested Directories

Phoenix 1.8.7 (phx_new default) configures esbuild and tailwind to output to **nested subdirectories**:

- esbuild: `--outdir=../priv/static/assets/js` → writes to `priv/static/assets/js/app.js`
- tailwind: `--output=priv/static/assets/css/app.css` → writes to `priv/static/assets/css/app.css`

Any assertion checking for flat asset paths (`priv/static/assets/app.js` or `priv/static/assets/app.css`) will silently fail to detect built output. Test assertions and CI gates must use nested paths.

Verification: run `mix phx.new <tempdir> --no-ecto && grep -n "outdir\|--output" config/config.exs` to confirm paths before trusting fixture assertions.

## Asset Build Race — Pre-Build Before Server Boot

`mix phx.server` (dev mode) builds assets via esbuild/tailwind **watchers AFTER the HTTP server boots**. A test framework waiting for HTTP 200 on `/` resolves before the first asset build completes. When the test's browser (Chromium) requests `/assets/css/app.css` or `/assets/js/app.js`, it encounters a 404.

**Symptom**: `FAIL:asset-404` in render-check output; flaky or deterministic failures depending on machine speed.

**Fix**: Pre-build assets (non-watch) inside `startPhoenixServer()` BEFORE spawning the dev server:

```js
// Pre-build assets (non-watch) so the first HTTP request finds compiled files
// on disk. mix phx.server's dev watchers build AFTER boot; this pre-build
// removes the cold-start race.
try {
    execFileSync("mix", ["assets.build"], {
        cwd,
        env: { ...process.env, MIX_ENV: "dev" },
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 120_000,
    });
} catch (err) {
    // Non-fatal: if assets.build is absent or fails, the dev watcher still
    // builds assets. This only removes the race.
    process.stderr.write("[phx] assets.build pre-build skipped: " + err.message + "\n");
}
// NOW spawn the server with pre-built assets on disk
spawn("mix", ["phx.server"], {...});
```

Use `assets.build` (not `assets.deploy`): dev-mode, no `phx.digest` fingerprinting needed for localhost testing.

## Coverage — Per-File

New `lib/**/*.ex` → per-file coverage above threshold. `cover/excoveralls.json`: `source_files[].name`=path, `.coverage`=array (0=uncovered, null=irrelevant, N=hit). 0-indexed → line = index + 1.

## Green-from-Birth Tests After Default-Arg Flips

When a function's default arg changes (e.g., `create_app/3 \\ "phoenix_with_db"` → `\\ "static_site"`), tests using arity-2 calls (omitting the arg) now get the new default. If a test asserts equality on a DB-URL-like fn: `assert database_url(app) == database_url(app, :prod)`, both sides return nil for static apps → assertion `nil == nil` passes trivially, never testing the actual 1-arity delegation contract. Such tests are "green from birth" — they pass before the fix despite never exercising the intended code path.

**Detection**: After default-arg flip, audit tests asserting `fn1(entity) == fn2(entity, mode)` on DB-URL / config-read / option-defaulting functions. If the entity's type determines both return values (static app → nil + nil, phoenix app → real URL + real URL), the test is green-from-birth.

**Fix**: Pass the old default explicitly as the 3rd+ arg so the entity type matches the intended test scenario. Example: `Apps.create_app(user.id, "App Name", "phoenix_with_db")` → database_url now returns real URL → assertion tests the real delegation contract.

**Pattern**: After default-arg flip, re-run tests and verify every equality assertion on type-sensitive fns. Coverage may pass (both branches visited in unrelated tests), but the equality itself is vacuous.

## Tautological Count Assertions

Count assertions using derived values from the same source list are vacuous and pass regardless of the actual fn output. Example:

```elixir
# ❌ tautological: always true
external_count = length(relpaths) - usage_count
assert length(relpaths) == external_count + usage_count  # reduces to: x == (x - y) + y
```

**Fix**: Assert against a literal constant (a known fixed value, not a computed variable):

```elixir
# ✅ asserts spec
assert external_count == 12  # the real @external_absolute_files count
assert usage_count == 68
```

Detection: any count test where the assertion's RHS is algebraically equivalent to the LHS (e.g., sums/differences cancel). These tests pass before and after changes, hiding bugs. Always source the expected value from a constant or independent fn, not derived arithmetic on the same source list.

## TDD — Red-Green-Refactor

1. RED: failing → confirm fails for right reason
2. GREEN: minimum → green
3. REFACTOR: clean while green

Simplest first. One at a time. Test behavior, not impl.

## Per-File Credo (MANDATORY)

`mix credo --strict path/to/file.ex` after each file. Common fails: single-fn pipelines, missing `@type` aliases in `@spec`, `@spec` on `defp`. Sweep: `grep -rn " |> " lib/ test/support/`. Final: `mix format --check-formatted && mix credo --strict`.

## Tests Assert Spec, Not Bug

```elixir
# ❌ encodes bug
assert Enum.any?(msgs, &String.contains?(&1, "unsupported"))
# ✅ asserts spec
refute Enum.any?(msgs, &String.contains?(&1, "unsupported"))
```

Bug fix → regression test. Scenario name: `test "does not crash when seed dir already exists"`.

## Include / Exclude

ALWAYS: Unit, Integration, Edge Cases. NEVER: Performance, Accessibility, Browser Compat, Security, Documentation, Layout Component Tests.

## Test Quality

- Behavior not loading: `"Remote Developer"` not `"Jobs"`
- `assert drop.id` not `assert drop.id != nil`
- `assert is_binary(result)` — no type+nil combos
- `describe "get_media_asset_url/1"` not `"... (Bug Fix)"`
- Integration test guards must assert ALL struct list fields including newly-added ones — prevents silent regressions when new fields are added to a struct

## ExUnit.CaptureLog Cross-Test Bleed in async: true Modules

`ExUnit.CaptureLog` is process-global: it installs a logger handler that captures log lines from ALL concurrent processes, not just the calling test. In `async: true` modules, a `capture_log` in one test can receive log lines emitted by other concurrently-running tests.

**Anti-pattern** (flaky):

```elixir
test "specific warning" do
  log = capture_log(fn -> some_operation() end)
  refute log =~ "unexpected response"  # ❌ flaky if another concurrent test also logs "unexpected response"
end
```

**Fix** (scoped assertions):

```elixir
test "specific warning" do
  log = capture_log(fn -> audit_tls_automation_ca() end)
  refute log =~ "audit_tls_automation_ca unexpected response"  # ✅ scoped to function-qualified string
end
```

Only use scoped warning strings (e.g., `"function_name unexpected response"`) that can ONLY be emitted by the function under test. This prevents concurrent test logs from matching the assertion and causing intermittent failures.

## Rules

- `async: true` default. ❌ `@tag :skip` (use `@moduletag :skip` at module scope).
- Flaky: `mix test test/file.exs:123 --repeat-until-failure 10000`
- `ExUnit.start(exclude: [:slow])` in `test_helper.exs`. One place.
- Append `2>&1`. ❌ `time`, ❌ pipe to `head`/`tail`/`grep`. Read log.

## LLM Integration Isolation

```bash
MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=1 mix test --only llm_integration path/to/test.exs
# Parallel:
MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=2 mix test --only llm_integration test/a_test.exs &
MIX_TEST_PARTITION=2 MIX_TEST_PARTITIONS=2 mix test --only llm_integration test/b_test.exs &
wait
```

`make llm`/`make llm-phoenix` handle partitioning. ❌ Same `MIX_TEST_PARTITION` concurrently.

## Backend Specs

Return-type change or new branches → update `@spec`, run `mix dialyzer` (PLT warm ~30-60s).

`test/support/*.ex` `@spec` → type aliases first:

```elixir
# ❌ Credo fail
@spec my_func(String.t()) :: {map(), String.t()}
# ✅
@type text :: String.t()
@type params :: map()
@spec my_func(text()) :: {params(), text()}
```

New `test/support/*.ex` at 0% → `coveralls.json` `skip_files` or write tests. ❌ `File.read!("lib/module.ex") |> assert =~ "string"` — call actual fn.

## GenServer

- `handle_info` + DB tests in `*SyncTest` `async: false`
- Open Ports via `:sys.replace_state/2`
- `:sys.get_state/1` after `Process.sleep/1`

## Race Pitfalls

- `File.cd!/2` + `async: true` → ParallelCompiler race. Fix: accept path args.
- `@on_load` must return `:ok`. Wrap `:erlang.load_nif` in `case`.
- `runtime.exs` overwrites `config/test.exs` mocks. Fix: `if config_env() != :test do … end`.
- `System.put_env` / `Application.put_env` → process-global mutation. Fix: define env-mutating tests in an `async: false` sibling `defmodule` in the same `.exs` file, with `on_exit` restore. Primary module (with other tests) stays `async: true`. Isolation: sibling modules in one file each run serially without blocking each other's async-true peers.

## BDD — Cucumber

`{:cucumber, "~> 0.4.1"}`. Features `test/features/**/*.feature`, steps `test/features/step_definitions/*_steps.exs`. Steps return `{:ok, context}`. Gate-only: `mix test.bdd`. Dev: targeted file. ❌ `mix test --only bdd` (leaves test server running).

## Coverage Workflow

Fix failing tests FIRST. Gate reports gap → `cover/excoveralls.json`. Dev reads JSON, adds targeted tests. `{ "minimum_coverage": 84.0 }`. After: `mix test --cover 2>&1 | grep TOTAL`, set `actual - 0.5`. `skip_files` for whole-file boilerplate; `# coveralls-ignore-start/stop` for UI scaffolding. ❌ ignore on business logic.

## Credo / Dialyzer / CI

Credo: ALL fixed. Exception: TODO/FIXME `exit_status: 0`. ❌ Remove TODO to "fix" Credo.

Dialyzer `runtime: false` deps: PLT `plt_add_apps: [:mix, :phoenix_test]` in `mix.exs`; targeted ignores in `.dialyzer_ignore.exs`; rebuild `rm -rf _build/*/dialyxir_* && mix dialyzer --plt`.

❌ Remove `--warnings-as-errors`. ❌ `test`→`test.ci`. Only `runtime.exs` runs at runtime. `Application.compile_env/3` bakes — crashes if `test.exs` differs. `Application.get_env/3` for varying. Refactoring: unit tests only, selectors lockstep backend → template → test.

## Multi-Module ExUnit Files

Single ExUnit file with multiple `defmodule` blocks: each module is an independent async unit. Private helpers defined in one module cannot be shared with sibling modules in the same file. Options:

- Promote shared helper to public fn in a support module (e.g., `test/support/fixtures.ex`)
- Keep private fn copy in each module that needs it (acceptable for small helpers like `count_commits!/1`)
- Consolidate sibling modules into a single `defmodule` if they share heavy test infrastructure

## Ecto Timestamp Handling in Tests

Ecto `:utc_datetime` rejects microseconds. When building stub DB records with future/past timestamps, always truncate to seconds:

```elixir
build(:llm_call, created_at: DateTime.truncate(DateTime.utc_now(), :second))
```

Postgres `date_trunc` returns `NaiveDateTime` (not `DateTime`). Functions handling DB-grouped results must match `%NaiveDateTime{}`.

## Coveralls Ignores in case Arms

`# coveralls-ignore-start`/`-stop` pragmas inside `case` arm bodies are accepted by `mix format` without reindenting. Use for wrapping genuinely-unreachable catch-all clauses.

## CLI Tool Testing (git, System.cmd)

Regression tests for CLI tool wrappers benefit from explicit artifact setup (symlinks, directories, cruft files) documenting the full scenario. Assertions on all artifact types (live symlink, live dir, unrelated cruft) provide complete coverage.

Example: `git clean` exclusion patterns tested by:

1. Init repo + create untracked artifacts: `File.mkdir_p!("public-123")`, `File.write!("public-123/index.html", ...)`, `File.ln_s!("public-123", "current")`, `File.write!("junk.txt", "cruft")`.
2. Assert three outcomes: `assert File.exists?("current")`, `assert File.dir?("public-123")`, `refute File.exists?("junk.txt")`.

Explicit setup documents intent (what should be protected vs. removed); full assertion coverage prevents silent failures when exclusion patterns drift.

## Recipes

`elixir-context-test-structure`, `req-test-stub-external-http`, `elixir-capture-logs-on-error-paths`, `mox-verify-on-exit-scope`, `task-supervisor-sandbox-allowance`, `elixir-async-false-triage`, `elixir-test-compile-env-config`, `github-workflows-mix-generator`.
