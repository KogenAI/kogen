# Test Benchmarking — BENCH Mode, Artifacts, Viewer

## Agent Prohibition

Agents MUST NEVER invoke `make test-stacks BENCH=1` or any benchmark-capture variant (`BENCH=1 REASON=...`). These commands burn real LLM token budget and run only at human-operator discretion. `make test-stacks` without `BENCH=1` stays agent-callable for the default pass/fail sweep.

## Benchmark Viewer (Mix Tasks) — Quick Reference

Run from `test_harness/`:

- `mix codegen.bench.list` — lists all runs under `codegen/benchmarks/` newest-first
- `mix codegen.bench.view --run codegen/benchmarks/<ts>` — ASCII metrics table for one run; add `--compare <prev>` for delta column

## Benchmark Prerequisites

Screenshot capture for static-stack benchmark runs requires:

- `node` — must be on `PATH`
- `playwright` npm devDependency — pinned at `^1.60.0` in root `package.json`; install via `npm install` at repo root
- Chromium browser binary — `make install` guarantees this on static-capable boxes; `make doctor` verifies. Manual install: `npx playwright install chromium`

**Two separate subsystems with different failure modes**:

1. **Benchmark screenshots** — `BenchArtifacts.capture_screenshot/4` (ExUnit test phase). Missing Playwright is **non-fatal**: logs warning and returns `:ok`. JSONL bench records always written.
2. **Static-site render gate** — `static-site-build-check.sh` (SubagentStop hook). **Fail-closed**: Chromium absent on a static-capable box blocks the developer subagent. The gate requires Chromium; benchmarks tolerate its absence.

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

PNG screenshot per static-stack and Phoenix test: `<BENCH_RUN_DIR>/runs/<harness>/<stack>/<test_name>.png` (1280×720 full-page, captured by `BenchArtifacts.capture_screenshot/4` via `test_harness/bench/screenshot.js`). Modes stack excluded — no website to render. Static stacks use a Node HTTP server; Phoenix stacks spawn `mix phx.server` on a dynamic port, poll for HTTP 200, capture the screenshot, then SIGTERM/SIGKILL the process group. Screenshot failure is non-fatal: test continues and JSONL is written regardless; missing Playwright logs a warning and returns `:ok`.

**Port allocation + cleanup infrastructure**: `bench_artifacts.ex` allocates free ports via `net.Server` on port 0 (captures `address().port`), passes to `mix phx.server` via `PORT=<n>` env. Timeout handling uses `Port.open/2` + `kill_port/1` (not `System.cmd/3`), covering deps.get (60s) + compile (90s) + readiness wait (30s) + screenshot (15s) = 210s total. Process cleanup: `process.kill(-pgid, 'SIGTERM')` → 2s wait → `SIGKILL`; catches ESRCH on normal exit. Both Node `stopPhoenixServer` and Elixir `kill_port/1` target the process, but cleanup order is correct (Phoenix finally-block runs first, avoiding race). Note: Edit tool requires prior Read (20260528 session); when Edit blocked on context files, use `sed -i ''` for in-place updates.

**Whiteness metric pitfall**: Light-themed SPAs with off-white backgrounds (e.g., `#f8f9fa`) register 99% white pixels in screenshots despite having content. Metric cannot distinguish blank from minimal UI. **Superseded** for gate-level emptiness detection by `harnesses/claude/hooks/lib/render-check.js`, which uses structural signals (DOM child count, author stylesheet rule count, UA-default body margin/font) instead of pixel colour. The PNG screenshots in bench runs remain visual references only — the render-check verdict is the authoritative gate signal.

**Bundle-marker regex precision**: Pattern `[^"']*\.\w+\.(js|mjs)` matches any `.foo.js`, not just hashed bundles. More specific pattern: `\.[a-zA-Z0-9]{8,}\.` for hash-like segments (8+ alphanumeric chars) to distinguish `/assets/index-HASH.js` (built) from `/src/main.jsx` (source). Current impl in `screenshot.js` `hasBundledScript` uses both checks: bundle marker presence + no source imports.

**Capture seam**: `Fixtures.run_codegen_build/3` pipes harness stdout to JSONL when `BENCH_RUN_DIR` env var is set. The seam reuses the same `maybe_write_diagnostics/2` mechanism that writes diagnostic reports in non-benchmark mode (the `maybe_write_diagnostics/2` clause in `fixtures.ex`).

**Per-test JSONL shape**: raw stream-json lines from codegen-build (claude line-1 = `system/init` with resolved model ID; pi envelope shape varies but final line always contains usage). Final synthetic record appended by harness:

```json
{"type":"harness_summary","test_name":"...","exit_code":0,"assertion_passed":false,"parsed":{...},"per_role":{...}}
```

`assertion_passed` is write-pending `false` at build time (written before ExUnit assertions run). After all assertions pass, `Fixtures.bench_assertions_passed!(stack, test_name)` flips it to `true` in-place by rewriting the last `harness_summary` line in the JSONL file. Tests that fail ExUnit assertions leave `assertion_passed: false` in the record.

**`per_role` map values are always integers**: The `per_role` key in `harness_summary` contains per-subagent token attribution (e.g., `{"planner-phoenix": {input_tokens: 100, output_tokens: 50, ...}, "orchestrator": {...}}`). Map values are accumulated token sums with default 0 per field — never `:unknown` atoms. Unlike the top-level `parsed` map (which carries `:unknown` atoms for missing Pi metrics), per-role sums are always concrete integers because aggregation only runs for roles that produced ≥1 assistant turn. The empty map `%{}` is the sole graceful-failure sentinel (Pi harness, pre-change JSONL, missing session_id). No `:unknown`-atom serialization pass is needed — the per_role map is JSON-encodable as-is (string keys, integer values).

**Modes tests bench records**: `run_mode_launcher/4` (4th `opts` arg, `test_name:` key; default `"<mode>_mode"`) now writes JSONL records under `runs/<harness>/modes/<test_name>.jsonl`. Records contain only a `harness_summary` line (no raw codegen stream-json prefix) with mostly `:unknown` parsed metrics — modes tests don't produce structured usage output. Finalize with `Fixtures.bench_assertions_passed!("modes", test_name)` after last assertion.

Parser (`CodegenTestHarness.UsageParser`) trims each harness envelope to `{model_id, tokens_in, tokens_out, cost_api, duration_ms}`. Pi tokens may be missing → stored as `:unknown` atom (not 0, which would hide data loss). Claude shape consistently provides all fields.

**Catalog module**: `CodegenTestHarness.BenchMetrics` — measurable metrics (pinned to values parsed above) + stub-with-gap entries (filled by viewer on comparison). No computed deltas at capture time; viewer calculates on load.

**Viewer Mix tasks** (run from `test_harness/`):

- `mix codegen.bench.list [root_dir]` — newest-first run listing with pass rate per (harness × stack)
- `mix codegen.bench.view --run <path> [--compare <prev>] [--test <filter>] [--metric <id>]` — ASCII metrics table; auto-picks previous run if `--compare` absent
- `node test_harness/bench/summarize.js <run-dir>` — reads every `runs/<harness>/<stack>/*.jsonl` `harness_summary` line, aggregates cost/tokens/duration/turns/pass-rate + screenshot counts, writes `<run-dir>/summary.md`; invoked automatically by `make bench`

`last_green.json` coexists unchanged; benchmarking is orthogonal to the green baseline.

## Regression Checker — `mix codegen.bench.check-regression`

Runs automatically at the end of `make bench` (after `summarize.js` writes `summary.md`), against `test_harness/perf_baseline.json`. **Not soft/informational-only end-to-end** — the split is per metric kind:

- **`min_abs` (currently only `pass_rate`)** — ALWAYS a hard failure, `--strict` or not. `pass_rate` sits at a ceiling (1.0) in normal operation, so any drop below `min_abs` (`0.9`) is unambiguous, not noise. A violation makes the task `exit({:shutdown, 1})`, and `make bench` propagates that as its own non-zero exit (unless the harness test-stacks step itself already failed, which takes priority).
- **`max_regression_pct` metrics** (turns/cost/duration/tokens) — informational-only by default: printed as a warning table, task still exits `:ok`. Pass `make bench BENCH_STRICT=1 REASON="..."` to promote these to hard failures too.
- **`baseline: 0`** — skipped entirely, never evaluated, regardless of `--strict`. Every `max_regression_pct` metric in the committed `perf_baseline.json` is still `0` (unpopulated) as of this writing — `pass_rate` is the only metric with a real baseline today.

**Populate a baseline from a single green `make bench` run at a pinned SHA** — never a hand-chosen number; that is the exact mistake this checker exists to catch. `perf_baseline.json`'s own `_note` field states this policy.

**Metric-kind split rationale** (why `pass_rate` gets ceiling treatment and the rest don't): `pass_rate` is a **guard** — bench tasks assert structural existence (e.g. `File.exists?("mix.exs")`, `commits_after > commits_before`), so a healthy run sits at 100% and any drop is a real break. `avg_num_turns` / `avg_cost_usd` / `avg_build_duration_ms` are **meters** — continuous, free to move either direction, and the ones that would actually show whether a prompt/rule change helped or hurt. Do not conflate the two: arming `avg_input_tokens` as a baseline guards _cost_, not context-window health (that figure is summed across turns and cache-dominated, not a peak-occupancy signal — see `context/claude-token-mechanics.md` for the per-turn distinction).

**Path note**: `@baseline_path` in the mix task is a compile-time-resolved path anchored to the module's own `__DIR__` (`test_harness/lib/mix/tasks/`) — it always resolves to the real, committed `test_harness/perf_baseline.json`, never test-injectable. Hermetic tests exercise the task against that real file with fixture JSONL run dirs; see `test_harness/test/mix/tasks/codegen_bench_check_regression_test.exs`.

## Trigger Keywords

BENCH=1, REASON, benchmark capture, screenshot, bench artifacts, mix codegen.bench, summarize.js, JSONL harness_summary, last_green.json coexistence, playwright, agent prohibition, make bench, make test-stacks BENCH, human-operator discretion, benchmark-coverage, makefile-targets, bench-prereqs
