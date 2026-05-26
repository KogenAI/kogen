# Testing — Phoenix / Elixir

## Sanctioned Commands

| Role                 | Allowed                                                                                     |
| -------------------- | ------------------------------------------------------------------------------------------- |
| developer-phoenix-\* | `mix test test/specific_test.exs` (single, no `--cover`); `:42`; `--trace path/to/file.exs` |
| reviewer-phoenix     | none                                                                                        |
| Gate (auto)          | `make ci`, `make ci-fast`, `make llm`, `make llm-phoenix`                                   |

`--trace` sets `--max-cases 1`, disables timeouts. Dev MUST NOT run `make ci`, bare `mix test`, `--cover`/`coveralls`. Zero Credo warnings, zero failures.

## Coverage — Per-File

New `lib/**/*.ex` → per-file coverage above threshold. `cover/excoveralls.json`: `source_files[].name`=path, `.coverage`=array (0=uncovered, null=irrelevant, N=hit). 0-indexed → line = index + 1.

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

ALWAYS: Unit, Integration, LiveView, Edge Cases. NEVER: Performance, Accessibility, Browser Compat, Security, Documentation, Layout Component Tests.

## Test Quality

- Behavior not loading: `"Remote Developer"` not `"Jobs"`
- `assert drop.id` not `assert drop.id != nil`
- `assert is_binary(result)` — no type+nil combos
- `describe "get_media_asset_url/1"` not `"... (Bug Fix)"`

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

## BDD — Cucumber

`{:cucumber, "~> 0.4.1"}`. Features `test/features/**/*.feature`, steps `test/features/step_definitions/*_steps.exs`. Steps return `{:ok, context}`. Gate-only: `mix test.bdd`. Dev: targeted file. ❌ `mix test --only bdd` (leaves test server running).

## Coverage Workflow

Fix failing tests FIRST. Gate reports gap → `cover/excoveralls.json`. Dev reads JSON, adds targeted tests. `{ "minimum_coverage": 84.0 }`. After: `mix test --cover 2>&1 | grep TOTAL`, set `actual - 0.5`. `skip_files` for whole-file boilerplate; `# coveralls-ignore-start/stop` for UI scaffolding. ❌ ignore on business logic.

## Credo / Dialyzer / CI

Credo: ALL fixed. Exception: TODO/FIXME `exit_status: 0`. ❌ Remove TODO to "fix" Credo.

Dialyzer `runtime: false` deps: PLT `plt_add_apps: [:mix, :phoenix_test]` in `mix.exs`; targeted ignores in `.dialyzer_ignore.exs`; rebuild `rm -rf _build/*/dialyxir_* && mix dialyzer --plt`.

❌ Remove `--warnings-as-errors`. ❌ `test`→`test.ci`. Only `runtime.exs` runs at runtime. `Application.compile_env/3` bakes — crashes if `test.exs` differs. `Application.get_env/3` for varying. Refactoring: unit tests only, selectors lockstep backend → template → test.

## Recipes

`elixir-context-test-structure`, `req-test-stub-external-http`, `elixir-capture-logs-on-error-paths`, `mox-verify-on-exit-scope`, `task-supervisor-sandbox-allowance`, `elixir-async-false-triage`, `elixir-test-compile-env-config`, `github-workflows-mix-generator`.
