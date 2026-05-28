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

## Pitfalls

- **`mix test` must be scoped** — bare `mix test` runs all ExUnit tests; always scope to file or tag (`--only phoenix`)
- **`last_green.json` is not auto-updated** — run `make record-green` explicitly after a clean passing suite
- **Hook tests are bash, not ExUnit** — do not run them via `mix test`; use `run-tests.sh`
- **`mix assets.deploy` exits 0 silently if alias undefined** — guard optional pipeline assertions with filesystem + config checks (check both `assets/` dir presence + `"assets.deploy"` alias in `mix.exs`) rather than assuming silent success means success
- **`count_commits!/1` duplicated across test modules** — candidate for promotion to public `Fixtures` fn to avoid copy-paste across `seed_test.exs` (static + phoenix)
- **Multi-module ExUnit files** — private helpers cannot be shared across modules in same file; promote to public in support module or keep private per-module copy
- **phx_new flags** — version 1.8.7+ does not support `--force` flag; scaffold via plain `mix phx.new . --app <name> --live`
- **CLAUDE.md scaffold instructions** — `Fixtures.isolated_tmp_dir/1` writes a CLAUDE.md gated behind non-phoenix stacks; ensure any direct scaffold calls mirror the exact `mix phx.new . --app <name> --live` incantation for consistency with fixture setup
