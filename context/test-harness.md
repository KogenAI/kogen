# Test Harness Domain — ExUnit Test Suite for Stacks

The test harness is an Elixir/ExUnit project in `test_harness/` that validates scaffold output and stack behaviour end-to-end. Tests scaffold a fresh app, run the generated code through real assertions, and record a passing baseline in `last_green.json`. `record-green.sh` stamps the last known-good commit SHA so regressions are detectable against a concrete baseline.

Tests live under `test_harness/test/stacks/` organized by stack (phoenix, static) and mode. The library code in `test_harness/lib/codegen_test_harness/` provides shared helpers.

`test_harness/test/stacks/modes/` (added in Stage 4) contains one test file per non-build mode — `debug_test.exs`, `shape_test.exs`, `refactor_test.exs`. Each invokes the harness×mode launcher non-interactively (claude: `--print --output-format text`; pi: `-p --mode json --no-session`) and asserts the mode-appropriate artifact: debug → diagnostic report in stdout + no files written; shape/refactor → draft pitch under `codegen/pitches/draft/`. These tests are `@moduletag :slow` and run under both `HARNESS=claude` and `HARNESS=pi` via the existing partition strategy.

## Components

| File / Dir                                            | Purpose                                                     |
| ----------------------------------------------------- | ----------------------------------------------------------- |
| `test_harness/mix.exs`                                | Elixir project definition — deps, test paths                |
| `test_harness/test/stacks/`                           | Stack-specific ExUnit test files (`*_test.exs`)             |
| `test_harness/test/test_helper.exs`                   | ExUnit config, global setup                                 |
| `test_harness/lib/codegen_test_harness/`              | Shared test helpers and assertion modules                   |
| `test_harness/lib/codegen_test_harness/assertions.ex` | Shared assertion helpers used across stack tests            |
| `test_harness/lib/codegen_test_harness/fixtures.ex`   | Fixture helpers for scaffold and generated output tests     |
| `test_harness/record-green.sh`                        | Records current commit SHA + timestamp to `last_green.json` |
| `test_harness/last_green.json`                        | Baseline: last commit SHA where full test suite passed      |

## Key Paths

```
test_harness/
  mix.exs
  test/
    test_helper.exs
    stacks/
      *.exs          ← per-stack ExUnit tests
  lib/
    codegen_test_harness/  ← shared helpers
  record-green.sh
  last_green.json
```

## ExUnit Test Modules

| Module (filename)         | Purpose                                                                  | Stack / Mode           |
| ------------------------- | ------------------------------------------------------------------------ | ---------------------- |
| `committer_test.exs`      | Validates committer phase output and commit message format               | Phoenix                |
| `gate_test.exs`           | Validates gate verdicts (ALL CLEAR / FAILED / INCONCLUSIVE)              | Phoenix                |
| `iteration_test.exs`      | Multi-step iteration and cycle continuity                                | Phoenix                |
| `scaffold_test.exs`       | Scaffold template rendering and output correctness                       | Phoenix                |
| `seed_test.exs`           | Database seed lifecycle and reproducibility                              | Phoenix                |
| `html_scaffold_test.exs`  | Static HTML scaffold template rendering                                  | Static                 |
| `iteration_test.exs`      | Multi-step static site iteration                                         | Static                 |
| `modes/debug_test.exs`    | Asserts debug launcher emits diagnostic report + writes no files         | Debug (claude + pi)    |
| `modes/shape_test.exs`    | Asserts shape launcher produces/edits draft pitch with Shape Up sections | Shape (claude + pi)    |
| `modes/refactor_test.exs` | Asserts refactor launcher produces draft pitch with refactor concern     | Refactor (claude + pi) |

## Make Target Catalog

| Target                    | Purpose                                                                  |
| ------------------------- | ------------------------------------------------------------------------ |
| `make test-stacks`        | Runs full ExUnit suite across all stacks (`mix test` in `test_harness/`) |
| `make test-stacks-claude` | Runs ExUnit suite for Claude harness only                                |
| `make test-stacks-pi`     | Runs ExUnit suite for Pi harness only                                    |
| `make record-green`       | Stamps `last_green.json` with current commit SHA after clean suite pass  |
| `make test`               | Runs bash hook tests (`run-tests.sh`) — separate from ExUnit suite       |

For full make-target index including install/uninstall/CI targets, see `context/development.md`.

## Integration Points

- **scaffold**: tests exercise `shared/scaffold/<stack>/scaffold.sh` output — scaffold changes require test updates; see `context/scaffold.md`
- **core**: `generate.sh` output (rendered agent files) may be asserted against in tests
- **development**: `make test-stacks` runs the ExUnit suite; `make record-green` stamps last_green after CI passes; see `context/development.md` for full make-target index
- **hooks**: hook bash tests (`*_test.sh`) are separate — run via `harnesses/claude/hooks/run-tests.sh`, not `mix test`; see `context/hooks.md`

## Testing Patterns

- Tests scaffold a temp app, assert generated file contents, run `mix compile` or `npm run build` on output
- `last_green.json` is checked in — diff against it to spot regressions before merging
- Run a single test file: `mix test test/stacks/phoenix_test.exs` from `test_harness/`
- Async: most stack tests are synchronous (file system I/O)
- **ExUnit concurrency**: `max_cases` (default `System.schedulers_online() * 2`) governs how many test _modules_ run in parallel. Tests within a single module always run serially, regardless of `async: true`. To maximize concurrency, split fat modules into multiple `defmodule` blocks per file (each becomes an independent async unit). `test_harness/test/test_helper.exs` omits `:max_cases` override — the default is sufficient. Partition infrastructure (`--partitions 4`) was dropped in commit 9b09dc8 after splitting `static/iteration_test.exs`, `static/seed_test.exs`, `static/scaffold_test.exs` into 14 modules; single `mix test` per harness now scales naturally.

## Fixture Isolation + Build Paths

`Fixtures.isolated_tmp_dir/1` creates separate temp directories for each harness test, with stack-specific config:

- `isolated_tmp_dir(stack: :phoenix)` — creates and pre-scaffolds a Phoenix app via `scaffold_phoenix_app!/1` before invoking harness
- `scaffold_phoenix_app!/1` runs `mix phx.new`, `mix deps.get`, and `git commit` in fixture setup, ensuring harness works on a real, git-tracked project
- Non-Phoenix stacks pass no `:stack` opt → directory is created empty (no scaffold pre-run)

**Build path isolation**: Tests using `mix` with non-default `MIX_BUILD_PATH=_build/pi_test` (pi tests) require recompilation of fixture-modified files under BOTH the default and custom build paths. A stale `_build/pi_test` still serves old BEAM bytecode after fixture changes until that tree is recompiled. Solution: run `mix compile` after fixture code edits without the env var, then again with the env var set.

**Arity + BEAM**: Functions defined with default args (e.g., `def f(opts \\ [])`) export both arity-0 and arity-1 in BEAM. A stale `.beam` under a non-default build path silently serves old signatures until recompilation.

**Environment isolation**: `System.cmd/3` with `env: []` clears the entire process environment — stripping PATH, HOME, MIX_HOME, HEX_HOME. Safe only for git (reads repo-local config). Mix commands need ambient environment (`env: :inherit` or omit `:env` option).

## Benchmarking mode (BENCH=1)

Enable with `BENCH=1 REASON="<description>"` on `make test-stacks`. Requires `REASON` to be non-empty (bench-prepare.sh exits 2 otherwise).

**Where files land**: `codegen/benchmarks/<YYYYMMDD_HHMMSS>/`

```
codegen/benchmarks/<UTC-ts>/
  reason.txt                   ← verbatim REASON string
  manifest.json                ← codegen SHA, harness versions, model_resolution
  runs/
    claude/
      phoenix/<test_name>.jsonl
      static/<test_name>.jsonl
      modes/<test_name>.jsonl
    pi/
      phoenix/<test_name>.jsonl
      static/<test_name>.jsonl
      modes/<test_name>.jsonl
```

PNG screenshot per static-stack and Phoenix test: `<BENCH_RUN_DIR>/runs/<harness>/<stack>/<test_name>.png` (1280×720 full-page, captured by `BenchArtifacts.capture_screenshot/4` via `bench/screenshot.js`). Modes stack excluded — no website to render. Static stacks use a Node HTTP server; Phoenix stacks spawn `mix phx.server` on a dynamic port, poll for HTTP 200, capture the screenshot, then SIGTERM/SIGKILL the process group. Screenshot failure is non-fatal: test continues and JSONL is written regardless; missing Playwright logs a warning and returns `:ok`.

**Port allocation + cleanup infrastructure**: `bench_artifacts.ex` allocates free ports via `net.Server` on port 0 (captures `address().port`), passes to `mix phx.server` via `PORT=<n>` env. Timeout handling uses `Port.open/2` + `kill_port/1` (not `System.cmd/3`), covering deps.get (60s) + compile (90s) + readiness wait (30s) + screenshot (15s) = 210s total. Process cleanup: `process.kill(-pgid, 'SIGTERM')` → 2s wait → `SIGKILL`; catches ESRCH on normal exit. Both Node `stopPhoenixServer` and Elixir `kill_port/1` target the process, but cleanup order is correct (Phoenix finally-block runs first, avoiding race). Note: Edit tool requires prior Read (20260528 session); when Edit blocked on context files, use `sed -i ''` for in-place updates.

**Whiteness metric pitfall**: Light-themed SPAs with off-white backgrounds (e.g., `#f8f9fa`) register 99% white pixels in screenshots despite having content. Metric cannot distinguish blank from minimal UI. **Superseded** for gate-level emptiness detection by `harnesses/claude/hooks/lib/render-check.js`, which uses structural signals (DOM child count, author stylesheet rule count, UA-default body margin/font) instead of pixel colour. The PNG screenshots in bench runs remain visual references only — the render-check verdict is the authoritative gate signal.

**Bundle-marker regex precision**: Pattern `[^"']*\.\w+\.(js|mjs)` matches any `.foo.js`, not just hashed bundles. More specific pattern: `\.[a-zA-Z0-9]{8,}\.` for hash-like segments (8+ alphanumeric chars) to distinguish `/assets/index-HASH.js` (built) from `/src/main.jsx` (source). Current impl in `screenshot.js` `hasBundledScript` uses both checks: bundle marker presence + no source imports.

**Capture seam**: `Fixtures.run_codegen_build/3` pipes harness stdout to JSONL when `BENCH_RUN_DIR` env var is set. The seam reuses the same `maybe_write_diagnostics/2` mechanism that writes diagnostic reports in non-benchmark mode (line 184 of fixtures.ex).

**Per-test JSONL shape**: raw stream-json lines from codegen-build (claude line-1 = `system/init` with resolved model ID; pi envelope shape varies but final line always contains usage). Final synthetic record appended by harness:

```json
{"type":"harness_summary","test_name":"...","exit_code":0,"assertion_passed":false,"parsed":{...}}
```

`assertion_passed` is write-pending `false` at build time (written before ExUnit assertions run). After all assertions pass, `Fixtures.bench_assertions_passed!(stack, test_name)` flips it to `true` in-place by rewriting the last `harness_summary` line in the JSONL file. Tests that fail ExUnit assertions leave `assertion_passed: false` in the record.

**Modes tests bench records**: `run_mode_launcher/4` (4th `opts` arg, `test_name:` key; default `"<mode>_mode"`) now writes JSONL records under `runs/<harness>/modes/<test_name>.jsonl`. Records contain only a `harness_summary` line (no raw codegen stream-json prefix) with mostly `:unknown` parsed metrics — modes tests don't produce structured usage output. Finalize with `Fixtures.bench_assertions_passed!("modes", test_name)` after last assertion.

Parser (`CodegenTestHarness.UsageParser`) trims each harness envelope to `{model_id, tokens_in, tokens_out, cost_api, duration_ms}`. Pi tokens may be missing → stored as `:unknown` atom (not 0, which would hide data loss). Claude shape consistently provides all fields.

**Catalog module**: `CodegenTestHarness.BenchMetrics` — measurable metrics (pinned to values parsed above) + stub-with-gap entries (filled by viewer on comparison). No computed deltas at capture time; viewer calculates on load.

**Viewer Mix tasks** (run from `test_harness/`):

- `mix codegen.bench.list [root_dir]` — newest-first run listing with pass rate per (harness × stack)
- `mix codegen.bench.view --run <path> [--compare <prev>] [--test <filter>] [--metric <id>]` — ASCII metrics table; auto-picks previous run if `--compare` absent
- `node test_harness/bench/summarize.js <run-dir>` — reads every `runs/<harness>/<stack>/*.jsonl` `harness_summary` line, aggregates cost/tokens/duration/turns/pass-rate + screenshot counts, writes `<run-dir>/summary.md`; invoked automatically by `make bench`

`last_green.json` coexists unchanged; benchmarking is orthogonal to the green baseline.

## Pitfalls

- **Leaf test summary line format is load-bearing** — each leaf test runner emits either `N passed, N failed` or `Results: N passed, N failed` (two pre-existing formats). Runner grep patterns require exact match of one format; any ad-hoc change breaks silent parse failure. Preserve each leaf's existing summary format verbatim; cross-leaf format normalization is out of scope for individual pitches.
- **Round-trip tests (install/uninstall) fail loud on missing tools** — tests require claude, jq, yq, rg, node on PATH; formerly self-skipped to green, now fail explicitly if tools absent (pitch INTENT: fresh-box provisioning must verify full toolchain). Operator must ensure `make test` box has all tools.
- **`mix test` must be scoped** — bare `mix test` runs all ExUnit tests; always scope to file or tag (`--only phoenix`)
- **`last_green.json` is not auto-updated** — run `make record-green` explicitly after a clean passing suite
- **Hook tests are bash, not ExUnit** — do not run them via `mix test`; use `run-tests.sh`
- **`mix assets.deploy` exits 0 silently if alias undefined** — guard optional pipeline assertions with filesystem + config checks (check both `assets/` dir presence + `"assets.deploy"` alias in `mix.exs`) rather than assuming silent success means success
- **`count_commits!/1` duplicated across test modules** — candidate for promotion to public `Fixtures` fn to avoid copy-paste across `seed_test.exs` (static + phoenix)
- **Multi-module ExUnit files** — private helpers cannot be shared across modules in same file; promote to public in support module or keep private per-module copy
- **phx_new flags** — version 1.8.7+ does not support `--force` flag; scaffold via plain `mix phx.new . --app <name> --live`
- **CLAUDE.md scaffold instructions** — `Fixtures.isolated_tmp_dir/1` writes a CLAUDE.md gated behind non-phoenix stacks; ensure any direct scaffold calls mirror the exact `mix phx.new . --app <name> --live` incantation for consistency with fixture setup
