# Parallel Test Module Split (async:true Wall-Time Fix)

**Problem**: A single `async: true` test module has grown so large that its sequential execution dominates CI wall time. Even though the module is `async: true`, tests inside one module always run sequentially within that module — parallelism only applies across modules.
**When**: One `async: true` file takes 60+ seconds, contains 50+ tests, and has naturally distinct concern groups (unit vs pipeline vs post-build vs saga).
**See also**: `elixir-sync-test-module-split.md`, `elixir-async-false-triage.md`

## The Hidden Bottleneck

`async: true` means the module runs concurrently _with other modules_ — not that tests within it run concurrently with each other. One 130s module is still 130s wall time regardless of how many cores you have. ExUnit can't parallelize within a single module.

## The Fix

Split into N modules, each `async: true`. ExUnit schedules all N in parallel. Wall time drops to the wall time of the _slowest_ module, not their sum. With 8 cores and 5 balanced modules, a 131s file becomes ~30-35s.

## How to Split

**Step 1** — identify slow describe blocks:

```bash
mix test path/to/test.exs --slowest 20
```

**Step 2** — group describe blocks by cost tier:

| Tier   | Characteristics                             | Target runtime |
| ------ | ------------------------------------------- | -------------- |
| Unit   | No DB, no Oban.perform, pure function tests | ~5s            |
| Medium | DB + Oban inline, medium Mox chains         | ~10s           |
| Heavy  | Full pipeline, `perform/1` with Mox chains  | ~25-30s        |

Aim for roughly equal _wall time_ per module, not equal _test count_.

**Step 3** — create new files, one per concern:

```
build_worker_test.exs            # 71 pure-unit tests   → ~6s
build_worker_parse_test.exs      # 18 parsing tests      → ~4s
build_worker_pipeline_test.exs   # 10 pipeline tests     → ~22s
build_worker_postbuild_test.exs  # 14 post-build tests   → ~25s
build_worker_saga_test.exs       # 26 saga/circuit tests → ~30s
```

Each file is `async: true`:

```elixir
defmodule MyApp.BuildWorkerPipelineTest do
  use MyApp.DataCase, async: true

  describe "full pipeline execution" do
    # tests moved here
  end
end
```

## Shared Helpers

- **Used by only one new module**: inline them directly in that file.
- **Used by multiple new modules**: move to `test/support/<domain>_helpers.ex` as a public module, `import` it in each test module. Only helpers and setup belong in `test/support/` — never test logic.
- **Module attributes** (`@some_value`): must be redeclared in each new module — they do not transfer.

## Naming Convention

`<Domain>Test`, `<Domain>PipelineTest`, `<Domain>PostBuildTest`, `<Domain>CircuitBreakerTest` — each in its own file, same directory as the original.

## Verification

Count tests before splitting:

```bash
grep -c 'test "' old_file.exs
```

Sum counts across all new files and confirm they match exactly. A mismatch means a test was accidentally dropped or duplicated.

## What NOT To Do

- Don't split into one file per describe block — 33 modules for 33 describes adds scheduler overhead and is hard to navigate.
- Don't add `async: false` to any new module to "balance" load — defeats the entire purpose.
- Don't move test logic into `test/support/` — only helpers and setup fixtures belong there.

## Concrete Example

From Combobulate `build_worker_test.exs` (139 tests, 131s → ~35s):

```
Before: one module, 131s wall time

After:
  build_worker_test.exs            71 tests  ~6s
  build_worker_parse_test.exs      18 tests  ~4s
  build_worker_pipeline_test.exs   10 tests  ~22s
  build_worker_postbuild_test.exs  14 tests  ~25s
  build_worker_saga_test.exs       26 tests  ~30s

Parallelized wall time: ~30s (slowest module), down from 131s
```

## Triggers

slow-tests parallel async-true module-split large-file wall-time scheduler concurrent describe-blocks ci-speed sequential-within-module
