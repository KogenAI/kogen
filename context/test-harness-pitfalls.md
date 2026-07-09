# Test Harness Pitfalls — ExUnit / Fixtures / Seams / Flakes

Elixir/ExUnit test gotchas for the codegen `test_harness/` suite that overflow
`context/test-harness.md`. Bash-generic test-technique idioms (RED-then-GREEN
proof patterns, PATH-stub, `git show HEAD` pre-fix fixtures) live in
`context/bash-patterns.md`; this file is Elixir/fixture/seam/flake-specific.

## npm Extension Parallel-Race Flake

When running `make test` (which includes TypeScript Pi extensions in parallel), occasional transient race-condition failures may occur in the extension test suites. The failure does NOT indicate code defects — the same tests pass when run individually via `cd harnesses/pi/pi-extensions/extension-name && npm run build && npm test`. Remedy: re-run `make test`. This is a known environmental race, not a gate blocker. If a single extension test passes in isolation but fails under `make test`, verify the extension has no shared state leakage (file handles, global variables, console stream restores in `finally` blocks on both success and error paths).

## Fixtures & Seams

- **Elixir Seam Threading — Preserving Test-Override Capacity**: When adding a new parameter to an Elixir function that is called in a default closure but tested via seam overrides, thread the parameter into the closure BINDING, not into the seam signature. Example: `OrchestrationLoop.invoke_role/4` has a `/6` `codegen_call_fn` seam. When the loop needs to pass a new `agent` parameter to `default_codegen_call`, it adds a trailing `:agent` param to `default_codegen_call/8` → `/9`. The loop's default closure in `invoke_role` binds `role` (already in scope) into the call, passing it as the new ninth argument. Tests that override `codegen_call_fn` via a seam do NOT change signature — they still receive `/6` args. The loop's default closure adapts internally without forcing test overrides to match. **Benefits**: zero churn to every test override (can be dozens across the suite); parameter added at the call site where it's known; seam stays a stable interface for tests. **When NOT to use**: when the parameter is genuinely part of the seam contract (every override MUST know about it) — thread it into the seam signature and update all test overrides instead.
- **RoleResolver Shape Changes and Sibling Test Ripple**: When a public function changes its return type, the shape change ripples to test files NOT explicitly listed in the edit scope. Example: a pitch naming `orchestration_loop_test.exs` but NOT `role_resolver_test.exs` still requires the sibling to be updated because `resolve_role`'s public contract changed (current contract: `resolve_role/2,3` returns `{model, effort}` — a 2-tuple, per `role_resolver.ex` `@spec`). **Fix**: before editing the primary target file, grep for ALL references to the function across `test_harness/test/` with keywords like `resolve_fn`, `resolve_role`, `codegen_call_fn` + the module name. A narrower grep scoped only to the plan's file list will miss sibling test files that stub the same functions. Update all test overrides/stubs in the same pass.
- `File.cd!/2` + `async: true` → ParallelCompiler race. Fix: accept path args.
- `@on_load` must return `:ok`. Wrap `:erlang.load_nif` in `case`.
- `runtime.exs` overwrites `config/runtime.exs` mocks. Fix: `if config_env() != :test do … end`.
- `System.put_env` / `Application.put_env` → process-global mutation. Fix: define env-mutating tests in an `async: false` sibling `defmodule` in the same `.exs` file, with `on_exit` restore. Primary module (with other tests) stays `async: true`. Isolation: sibling modules in one file each run serially without blocking each other's async-true peers.
- Private helpers per-module only — cannot share across modules in same file; promote to public support module or duplicate.
- **Environment isolation**: `System.cmd/3` with `env: []` clears the entire process environment — stripping PATH, HOME, MIX_HOME, HEX_HOME. Safe only for git (reads repo-local config). Mix commands need ambient environment (`env: :inherit` or omit `:env` option).
- **Parallel build-path isolation**: When running multiple independent test suites concurrently (e.g., `-j2` for `test-stacks-claude` and `test-stacks-pi`), each test harness must use a distinct `MIX_BUILD_PATH` to avoid BEAM artifact clobbering. Example: parity test uses `MIX_BUILD_PATH=_build/parity_test`, separate from the default `_build/claude_test` and `_build/pi_test` used by the per-harness stack suites.
- **Build path isolation**: Tests using `mix` with non-default `MIX_BUILD_PATH=_build/pi_test` (pi tests) require recompilation of fixture-modified files under BOTH the default and custom build paths. A stale `_build/pi_test` still serves old BEAM bytecode after fixture changes until that tree is recompiled. Solution: run `mix compile` after fixture code edits without the env var, then again with the env var set.
- **Arity + BEAM**: Functions defined with default args (e.g., `def f(opts \\ [])`) export both arity-0 and arity-1 in BEAM. A stale `.beam` under a non-default build path silently serves old signatures until recompilation.

## Flake Triage & Race Pitfalls

- **`bench_artifacts_test.exs` token list tracks screenshot.js changes** — update on Vite migration.
- **`default_spawn_fn/5` timeout kills whole child tree** — `Port.open`+receive-loop, not `Task.shutdown(:brutal_kill)` (orphans grandchildren). Seams: `:__queue_drain_build_bin__`, `:__queue_drain_kill_fn__`.
- **`Task.shutdown(:brutal_kill)` doesn't kill OS children** — Use `Port.open` + process-group kill instead.
- Round-trip tests fail loud on missing tools — require claude, jq, yq, rg, node on PATH; fail explicitly if absent.
- Gate-failure-path tests are `:slow` — verdict != "clear" tests require real hooks; tag `:slow`, run only `make test-stacks`.

## Ecto / Port / Timestamp Gotchas

- **Ecto Timestamp Handling in Tests**: Ecto `:utc_datetime` rejects microseconds. When building stub DB records with future/past timestamps, always truncate to seconds: `build(:llm_call, created_at: DateTime.truncate(DateTime.utc_now(), :second))`. Postgres `date_trunc` returns `NaiveDateTime` (not `DateTime`). Functions handling DB-grouped results must match `%NaiveDateTime{}`.
- **`Port.open` `:env` requires charlist tuples** — `{:env, [{"KEY","VAL"}]}` raises error; use `{:env, [{~c"KEY", ~c"VAL"}]}`. See `fixtures.ex` + `bench_artifacts.ex` for ref pattern.
- **Elixir epoch-to-UTC-stamp pattern**: Use `Calendar.strftime(DateTime.from_unix!(ts), "%Y%m%d*%H%M%S")` only at filename construction; keep `now_fn` raw integer elsewhere.
- **`run_with_timeout/4` return order** — returns `{output, exit_code}` (output-first); re-tuple explicitly if contract differs.
- **`codegen-call` requires `--model`, `--effort`, `@<abs-path>`** — old API used exit 2; fixtures resolve from config.yaml, write temps, pass @/tmp/...
- **`assert_assets_deploy!` needs `MIX_ENV=dev`** — tailwind config is dev-only; pass `env: [{"MIX_ENV", "dev"}]` in System.cmd call.
- **`mix assets.deploy` silent no-op risk** — guard assertions with filesystem checks (assets/ dir + alias in mix.exs).
- **`phx_new` 1.8.7+ no `--force`** — scaffold via `mix phx.new . --app <name> --live` (no --force flag).
- **New `_fn` seam default in shared test helper** — Add seam default to base-opts to avoid real slow defaults in pre-existing tests. Example: `base_opts/2` must default `:discover_session_log_fn` seam to fast `fn -> nil end` to skip 30s sleeps.
- **Capturing return value + stderr with `capture_io`** — `capture_io(:stderr, fn -> result end)` swallows the block's return. Recovery: `send(self(), {:result, <call>})` inside, then `receive do {:result, r} -> r end` outside to recover both output AND value.
- **Direct function calls bypass seam overrides** — Tests calling a function directly invoke the real default even if caller overrode the seam. Fix: expose poll limit as public parameter with production-safe default, so direct tests can override. Arity-N seam still works (Elixir auto-generates lower-arity clause).

## Trigger Keywords

test harness pitfall, exunit fixture, seam override, flake triage, ecto timestamp, port env charlist, npm extension race, role resolver ripple, seam threading, build path isolation, mix build path, arity beam stale, capture_io return value

## Update When Changing

- `test_harness/` fixtures, seam signatures, flake-prone tests
- New ExUnit gotchas that would otherwise overflow `context/test-harness.md`'s byte cap
