# Test Harness Domain — ExUnit Test Suite for Stacks

The test harness is an Elixir/ExUnit project in `test_harness/` that validates scaffold output and stack behaviour end-to-end. Tests scaffold a fresh app, run the generated code through real assertions, and record a passing baseline in `last_green.json`. `record-green.sh` stamps the last known-good commit SHA so regressions are detectable against a concrete baseline.

Tests live under `test_harness/test/stacks/` organized by stack (phoenix, static) and mode. The library code in `test_harness/lib/codegen_test_harness/` provides shared helpers.

`test_harness/test/stacks/modes/` (added in Stage 4) contains one test file per non-build mode — `debug_test.exs`, `shape_test.exs`. Each invokes the harness×mode launcher non-interactively (claude: `--print --output-format text`; pi: `-p --mode json --no-session`) and asserts the mode-appropriate artifact: debug → diagnostic report in stdout + no files written; shape → draft pitch under `codegen/pitches/draft/`. The `refactor` mode has been removed; the live mode launchers are shape, debug, and ops. These tests are `@moduletag :slow` and run under both `HARNESS=claude` and `HARNESS=pi` via the existing partition strategy.

## Components

| File / Dir                                                    | Purpose                                                                                                                                                                                 |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_harness/mix.exs`                                        | Elixir project definition — deps, test paths                                                                                                                                            |
| `test_harness/test/stacks/`                                   | Stack-specific ExUnit test files (`*_test.exs`)                                                                                                                                         |
| `test_harness/test/test_helper.exs`                           | ExUnit config, global setup                                                                                                                                                             |
| `test_harness/lib/codegen_test_harness/`                      | Shared test helpers and assertion modules                                                                                                                                               |
| `test_harness/lib/codegen_test_harness/assertions.ex`         | Shared assertion helpers used across stack tests                                                                                                                                        |
| `test_harness/lib/codegen_test_harness/fixtures.ex`           | Fixture helpers for scaffold and generated output tests                                                                                                                                 |
| `test_harness/lib/codegen_test_harness/role_resolver.ex`      | Resolves `{role, harness}` → `{system_prompt_path, model, effort, allowed_tools}` via `config.yaml` + agent `.md`. **Critical**: reads `.harness.<role>.<harness>.*` keys (e.g. `.harness.ops.claude.model`), NOT `.roles.<role>.*` keys which are read by live launchers (e.g. `claude-ops.sh` reads `.roles.ops.model`). These are distinct config blocks. Hermetic tests in `role_resolver_test.exs`.                          |
| `test_harness/lib/codegen_test_harness/orchestration_loop.ex` | Deterministic cycle driver: sequences roles per stack, invokes each via `RoleResolver` → `codegen-call`, runs the gate via `LoopGate`. Hermetic tests in `orchestration_loop_test.exs`. |
| `test_harness/lib/codegen_test_harness/loop_gate.ex`          | Runs the gate as a loop step by shelling `gate-select.sh`/`gate-result.sh` — no gate-logic reimplementation.                                                                            |
| `test_harness/lib/codegen_test_harness/loop_queue.ex`         | Kahn topo-sort + transient-error classification; ported from removed `build-queue.sh`. See "Orchestration Loop" § below. Tests: `loop_queue_test.exs`. |
| `test_harness/lib/codegen_test_harness/loop_queue_drain.ex`   | Multi-pitch drain — `LoopQueue`'s live caller. See "Orchestration Loop" § below. Tests: `loop_queue_drain_test.exs`. |
| `test_harness/lib/mix/tasks/codegen.loop.ex`                  | `mix codegen.loop --harness=<claude_code\|pi> --stack=<phoenix\|static> --cwd=<dir> <pitch>` — entrypoint `dispatch.sh`'s build path execs.                                             |
| `test_harness/lib/mix/tasks/codegen.loop.queue.ex`            | `mix codegen.loop.queue --harness=<claude\|pi> --stack=<S> --cwd=<dir>` — wraps `LoopQueueDrain.drain/1`; invoked by `--queue` launcher flags. |
| `test_harness/record-green.sh`                                | Records current commit SHA + timestamp to `last_green.json`; accepts `--auto-commit` flag for scoped fail-soft commit                                                                   |
| `test_harness/last_green.json`                                | Baseline: last commit SHA where full test suite passed                                                                                                                                  |
| `test_harness/test/harness_parity/pi_parity_test.exs`         | Cross-harness build parity tests (claude vs pi); tagged `@moduletag :harness_parity`                                                                                                    |
| `test_harness/test/harness_parity/known_divergent.exs`        | Divergence allowlist — ships empty; add tuples `{scenario, harness, reason}` for legitimate divergences                                                                                 |

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

| Module (filename)                                     | Purpose                                                                                         | Stack / Mode            |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------- |
| `committer_test.exs`                                  | Validates committer phase output and commit message format                                      | Phoenix                 |
| `gate_test.exs`                                       | Validates gate verdicts (ALL CLEAR / FAILED / INCONCLUSIVE)                                     | Phoenix                 |
| `iteration_test.exs`                                  | Multi-step iteration and cycle continuity                                                       | Phoenix                 |
| `scaffold_test.exs`                                   | Scaffold template rendering and output correctness                                              | Phoenix                 |
| `seed_test.exs`                                       | Database seed lifecycle and reproducibility                                                     | Phoenix                 |
| `iteration_test.exs`                                  | Multi-step static site iteration                                                                | Static                  |
| `test_harness/test/stacks/modes/debug_test.exs`       | Asserts debug launcher emits diagnostic report + writes no files                                | Debug (claude + pi)     |
| `test_harness/test/stacks/modes/shape_test.exs`       | Asserts shape launcher produces/edits draft pitch with Shape Up sections                        | Shape (claude + pi)     |
| `test_harness/test/harness_parity/pi_parity_test.exs` | Cross-harness parity: phoenix-minimal, static-minimal (claude vs pi). Tagged `:harness_parity`. | Parity (both harnesses) |

## Orchestration Loop (`OrchestrationLoop`/`LoopGate`/`LoopQueue`/`LoopQueueDrain`)

Deterministic Elixir replacement; selected by `--elixir` on `codegen-build` (exports `CODEGEN_BUILD_ELIXIR`, no TTY auto-detect). Present → `dispatch.sh` execs `mix codegen.loop`; absent (default) → legacy self-orchestrating session. Rejects `--elixir` + `--resume-id`/`--resumable` (not resumable). Shared ExUnit helpers (`run_codegen_build/3`, `run_codegen_build_parity/4` in `fixtures.ex`) pass `--elixir`.

- `OrchestrationLoop.role_sequence/1` — Phoenix plan-first; static developer-first.
- `OrchestrationLoop.run/1` — sequences roles via `invoke_role/4` (real `RoleResolver.resolve_role/2` → `codegen-call`), interleaves `LoopGate.run_gate/2` after the developer role. Envelope `result.status`: `"success"` advances, `"failed"`/`"clarifying_question"` retries SAME role once then `{:error, reason}`; other shapes RAISE. Gate verdict BINARY (`:clear|:failed`); RAISES on stray verdict. `stack: "static"` runs `:preflight_fn` before gate — RAISES naming missing dep (node/render-check.js/chromium). Phoenix skips preflight.
- **Reviewer→dev fix cycle** — reviewer ends with `REVIEW_VERDICT: APPROVED|CHANGES_REQUESTED`. `CHANGES_REQUESTED` re-invokes dev with feedback, re-formats, re-gates, re-reviews (within `:max_review_cycles`, default 1).
- **Committer verification** (`verify_committed!/1`) — after committer succeeds, asserts `git status --porcelain` empty in `ctx.cwd`; dirty tree RAISES. No-op on non-git cwd (mocked tests).
- **Cwd-threaded calls** — `invoke_role/4`'s default `codegen_call_fn` closes over `ctx.cwd`, calls `default_codegen_call/8` (cwd first arg, transcript last arg, `System.cmd(cd: cwd)`) so each role's agent runs IN the project dir. Test seam stays `/6`.
- **Per-role transcript capture (optional)** — `mix codegen.loop` derives `cycle_id="<stamp>_<slug>"` (single-pitch entry; queue inherits via child subprocess), threads into `run(cycle_id: ...)`. `invoke_role/4` computes `transcript_path/4` = `<cwd>/codegen/logging/<cycle_id>/NN-<role>.jsonl` (nil cycle_id → nil, no-op) → `CODEGEN_CALL_TRANSCRIPT_PATH` env; both `call-dispatch.sh` copy their temp stream-json there on EXIT (fail-loud-non-blocking). `write_cycle_summary/6` appends `{role,seq,num_turns,cost_usd,status,transcript}` per invocation to `cycle-summary.jsonl` in the same dir. Gitignored.
- **Telemetry** — `accumulate_telemetry/2` sums each envelope's `usage` (cost/tokens/turns) into a process-dict accumulator (`get_telemetry/0`/`zero_telemetry/0`) per role, across all invocations incl. retries. `Mix.Tasks.Codegen.Loop.emit_loop_telemetry/1` prints one aggregated `{"type":"result",...}` JSON line after `run/1` regardless of outcome, for the benchmark harness.
- **`stack_default_gate/2`** (`LoopGate`, private) — `gate-select.sh`'s stack-blind fallback picks `"make test"` for non-mix.exs; loop's static sequence has no planner `**Gate**:` line, so this forces static + `"make test"` → `"make ci"`. Loop-local; shared `gate-select.sh` untouched.
- **`call-dispatch.sh` flip** — both harness `call-dispatch.sh` scripts now pass `--append-system-prompt` (not `--system-prompt`) unconditionally, no toggle.
- `guard_bundle_flag!("claude_code")` defaults to committed minimal loop bundle `harnesses/claude/claude-code-loop-settings.json` (8 role-agnostic hooks), not full settings.json — loop calls run without role identity. See `context/core.md` § Loop Settings Bundle (`LOOP_BUNDLE_IDS`). Legacy path unaffected (no caller of `guard_bundle_flag!/2`).
- Test seams: `:invoke_fn`, `:gate_fn`, and (on `invoke_role/4`) `:resolve_fn`/`:codegen_call_fn` opts let tests stub the LLM/gate entirely. Use `Keyword.merge(defaults, extra)` NOT `list1 ++ list2` when merging `_fn` opts (left wins in concat, right wins in merge — applies to all seam-based test helpers, e.g. `orchestration_loop_test.exs`, `loop_queue_drain_test.exs`).
- `LoopGate.run_gate/2` shells `gate-select.sh`/`gate-result.sh` — reuses `codegen/gate-pending/` JSON schema unchanged.
- **Single-pitch move** (`OrchestrationLoop.run/1` `:ok` branch) — calls `maybe_ship_pitch/2` to move `ready/<slug>.md` → `shipped/<slug>.md` (idempotent, clean-tree-guarded). Mirrors queue discipline. Tests in `codegen_loop_test.exs`.
- `LoopQueue` mirrors `retryable_regex` transient and Kahn topo-sort. `LoopQueueDrain.drain/1` live caller: `--elixir --queue` execs `mix codegen.loop.queue`; bare `--queue` execs legacy `harnesses/shared/build-queue.sh`. Both share `codegen/gate-pending/` lock. **Operator output**: per-pitch banner, two-path echo (session.md + jsonl, fail-open), streamed child stderr, terminal outcomes; session.md discovery via glob ≤30 polls. Tests: `loop_queue_drain_test.exs`. **Per-pitch engine**: `default_spawn_fn/5` passes `--elixir` in the per-pitch `codegen-build` child args (engine=elixir throughout under `--elixir --queue`).
- **Committed-but-nonzero recovery** — `handle_nonzero_exit/5` detects committer-post-commit hiccup (HEAD moved + gate `"clear"`) and counts pitch shipped instead of erroring. Seams `:git_head_fn`, `:gate_verdict_fn` fail-open. Only `"clear"` recovers; others halt loud. Tests: `loop_queue_drain_test.exs` (`6r1`-`6r6`).
  - **Idempotency contract**: `LoopQueueDrain.ship/3` MUST be idempotent (return `:ok` if dst exists) — the build agent already moves ready→shipped per baked system-prompt contract; drain never fights it for ownership.
- State advancement (GATED→REVIEWED→CURATED→COMMITTED) shells `cycle-state.sh` via `advance_cycle_state_step/3`.
- **Cutover complete**: in-harness self-orchestration (SubagentStop/Stop role-sequencing, orchestrator rules, curator-format.sh, etc.) DELETED. `build-queue.sh` NOT deleted — LIVE default `--queue` drainer (above). Loop/legacy coexist via `--elixir` (legacy default) for build AND `--queue` leg. Prompt-body files retained for legacy engine in dispatch.sh.
- **Pitch-path resolution contract** — `dispatch.sh` runs `cd "$LOOP_DIR"` (`$LOOP_DIR` = `<repo>/test_harness/`) before execing `mix codegen.loop`. Any mix task resolving a relative file path (pitch arg, draft slug) MUST join it against the explicit `--cwd` flag (the real project root), never `File.cwd!()`. Pattern: `Path.expand(relative_path, cwd)`. Applies to any future mix task accepting a file-path arg.

## Make Target Catalog

| Target                       | Purpose                                                                                                                     |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `make test-stacks`           | Runs full ExUnit suite across all stacks (`mix test --only slow`; real LLM)                                                 |
| `make test-stacks-claude`    | Runs ExUnit suite for Claude harness only (`mix test --only slow`)                                                          |
| `make test-stacks-pi`        | Runs ExUnit suite for Pi harness only (`mix test --only slow`)                                                              |
| `make test-hermetic`         | Fast, deterministic ExUnit only (`mix test --exclude slow`); no LLM                                                         |
| `make test`                  | Bash hook tests + hermetic ExUnit (`test-hermetic`) — no LLM                                                                |
| `make record-green`          | Stamps `last_green.json` with current commit SHA after clean `test-stacks`                                                  |
| `make test-harness-parity`   | Runs cross-harness parity suite (`--only harness_parity`, distinct `_build/parity_test`); runs once as `test-stacks` prereq |
| `make check-green-staleness` | Diagnostic: exits 1 if `last_green.json` is >7 days old; standalone, not a `test`/`test-stacks` prereq                      |

## Gate Invariant: `--only slow` / `--exclude slow` & Hermetic Assertions

The ExUnit suite uses `@moduletag :slow` to partition LLM-driven tests from deterministic fast tests:

- `make test-stacks-claude` / `make test-stacks-pi` → `mix test --only slow` — only runs LLM-dependent tests tagged `:slow`
- `make test-hermetic` → `mix test --exclude slow` — only runs fast, deterministic tests

**Critical**: tests added to the gate suite (e.g., `ops_test.exs`, `headless_launcher_test.exs`) MUST have `@moduletag :slow` to be included in `make test-stacks`. Omitting the `:slow` tag silently excludes them from the LLM gate via `test_helper.exs: exclude: [:slow]` — they will run under `test-hermetic` instead, defeating gate coverage.

**Deterministic vs. slow test placement**: When adding a new test that does NOT call the actual agent binary (stubs via `System.cmd` with mocked binaries), the test MUST NOT carry `@moduletag :slow` — it runs under `make test` hermetic ExUnit. Example: `build_test.exs` stubs the codegen-build binary (`codegen-build`) and runs from a nested `codegen/pitches/` cwd, verifying launcher path normalization; deterministic assertions (exit 0, arg capture, mention prefix correctness) mean no `@moduletag :slow` — runs at `make test` time, not `make test-stacks`. This avoids cold-compile costs for every full suite invocation while ensuring the contract is tested.

**Multiple exclusion tags work correctly**: When `test_helper.exs` specifies `exclude: [:slow, :harness_parity]` and a test file uses `@moduletag :slow` + `@moduletag :harness_parity`, both tags are correctly excluded by `mix test --exclude slow`. No interaction issues; the exclude list is ANDed (all listed tags are excluded).

### Deterministic vs. LLM-Driven Assertions

Scaffold tests split assertions by gate:

- **Hermetic (`make test`)**: File presence (PROJECT_CONTEXT, restart_server.sh, usage_rules_INDEX), gitignore entries, idempotency (marker count), zero boundary violations (`grep -ri "<consumer-name>"` = 0), git log non-empty (repo committed)
- **Slow (`make test-stacks`)**: LLM-driven assertions (build completion, rendered content correctness), clean tree (`git status --porcelain` empty post-commit), all hermetic assertions above

Boundary guard (grep for consumer name) runs in both: hermetic bash tests via `scaffold_test.sh`, slow ExUnit via file-present assertions. Misses can slip through if hermetic guard only scopes to a subset of files — expand grep target to include all files that could carry the consumer name.

**Important caveat — `--only <tag>` matching empty tests**: When no tests match a tag filter (e.g., no `--only slow` tests), `mix test` exits with **exit code 1** (not 0). This is a safety mechanism — an empty partition cannot fake-green. However, the risk is NOT an empty match; it is silent exclusion of untagged tests. A module without explicit tags is excluded by `--only slow`, and if that module is the only build-path test for a critical feature, gate coverage has a hole.

**Proof of G1 fix**: `ops_test.exs`/`headless_launcher_test.exs` were tagged `:ops`/`:headless` but NOT `:slow`. Adding `@moduletag :slow` to both raised the gate's reported test count by their case counts; both tags kept for dual inclusion. Invariant holds: never regress to bare `mix test` (silently disables `exclude: [:slow]`, masks gate effectiveness).

## Assertion Coverage Pattern

Assertion helper functions defined in `CodegenTestHarness.Assertions` should be reused across multiple test cases when they guard important postconditions (e.g., `assert_assets_deploy!`, `assert_generated_tests_pass!`). When an assertion is defined but has zero call sites, it represents a regression-guard gap — identify where that assertion logically belongs and wire it into at least one test case. Example: `assert_assets_deploy!/1` validates compile-first alias ordering (the `assert_assets_deploy!` block in `assertions.ex`); it was wired into `no_ecto_scaffold_test.exs` (the `mix assets.deploy` test case) to ensure `mix assets.deploy` succeeds under `--no-ecto` scaffold, a key compile precondition. Scan newly defined assertions during review; if a helper has no callers, route it to the test file that should guard it.

**Static scaffold outDir configuration**: The Vite static scaffold explicitly sets `outDir: "public"` (not the Vite default `dist/`). Any test assertion, hook, or tooling checking for built output must use `public/` as the expected output directory, not `dist/`. Path-string mismatches (e.g., assertions expecting `dist/index.html` when the scaffold writes to `public/index.html`) are NOT caught by hermetic `make test` (string literals compile fine) — only real LLM builds via `make test-stacks` would surface the mismatch. Audit all output-path expectations (assertions.ex, fixtures.ex, hook scripts, bench verifiers) for `dist/` references when touching static stack output paths.

## Bash Hook Test Debugging — Silent Crashes & Early Exits

When bash hook tests show a pattern of ALL blocking tests failing while non-blocking tests pass, **suspect an early fatal crash (unbound variable under `set -u`, syntax error) rather than logic errors**. The hook exits non-zero BEFORE reaching the `block()` call, so the verdict JSON is never emitted and the output appears empty — this looks like "allow" to the test harness (no block JSON = PASSED).

**Diagnostic pattern**: Run the hook in isolation with `set -x` to trace execution: `bash -x harnesses/claude/hooks/your-hook.sh 2>&1 | head -50`. Look for the line where execution stops (the last line printed before exit) — typically a variable reference before assignment (e.g., `write_cycle_state "..." "$project_dir" ...` when `project_dir` was assigned later in the script under `set -u`). Fix by **hoisting variable assignments before first use**, or by guarding with `${var:-}` if the variable is optional.

**Test implication**: When a hook test suite suddenly goes from "all pass" to "all blocking tests fail", do NOT assume logic regression — check for unbound-variable crashes first. Run a single test case with `bash -x` to confirm the hook's execution trace reaches the intended block-decision point.

## npm Extension Parallel-Race Flake

When running `make test` (which includes TypeScript Pi extensions in parallel), occasional transient race-condition failures may occur in the extension test suites. The failure does NOT indicate code defects — the same tests pass when run individually via `cd harnesses/pi/pi-extensions/extension-name && npm run build && npm test`. Remedy: re-run `make test`. This is a known environmental race, not a gate blocker. If a single extension test passes in isolation but fails under `make test`, verify the extension has no shared state leakage (file handles, global variables, console stream restores in `finally` blocks on both success and error paths).

## Hermetic Regression Guards

Two new test files in `test_harness/test/codegen_test_harness/` run under `make test-hermetic` (do NOT carry `@moduletag :slow`; only hermetic tests):

- **`render_check_test.exs`** — Validates `harnesses/claude/hooks/lib/render-check.js` syntax correctness via `node --check` on both render-check.js and phoenix-server.js. Smoke-invokes `render-check.js` asserting a `RENDER_VERDICT=` line emits (catches silent parse failures). Skips-with-reason if `node` absent (browserless box allowed). Critical for catching render-check regressions without requiring a full LLM gate cycle.
- **`call_contract_test.exs`** — Asserts the harness-name mapping: `Fixtures.codegen_call_harness/0` returns `"claude_code"` (codegen-call harness name), not `"claude"` (codegen-build harness name). Catches class-2 regressions where fixture feeds wrong harness ID to the call binary.

### Hermetic Role-Absent Testing Pattern for codegen-call

`Fixtures.run_codegen_call/3` derives `--model` and `--effort` flags from `config.yaml` by role → a **real role string is required**. This helper cannot serve as a test vehicle for role-absent cases. Instead, hermetic role-absent tests trigger via a **different missing argument** (e.g., `--harness`) that causes exit 2 with usage text, then assert the usage message is emitted. Pattern: `System.cmd("codegen-call", [missing args that trigger exit 2], ...)` and `assert {_, 2} = result`, then inspect stdout for usage text mentioning `--harness`. This approach validates the role-optional behavior without requiring dispatch through the role-resolution path.

**G1–G3 confidence gaps (historical, closed)**: G1 `ops_test.exs`/`headless_launcher_test.exs` tagged `:slow`. G2 `assert_generated_tests_pass!/1` broadened to ≥4 call sites. G3 removed silent-pass on empty wildcard in seed_test.exs.

For full make-target index including install/uninstall/CI targets, see `context/development.md`.

## Integration Points

- **scaffold**: tests exercise `shared/scaffold/<stack>/scaffold.sh` output — scaffold changes require test updates; see `context/scaffold.md`
- **core**: `generate.sh` output (rendered agent files) may be asserted against in tests
- **development**: `make test-stacks` runs the ExUnit suite; `make record-green` stamps last_green after CI passes; see `context/development.md` for full make-target index
- **hooks**: hook bash tests (`*_test.sh`) are separate — run via `harnesses/claude/hooks/run-tests.sh`, not `mix test`; see `context/hooks.md`

## Testing Patterns

### Hermetic Bash Test Assertion Pattern

Hermetic bash tests (e.g., `*_test.sh` hook tests) should assert on **committed, in-repo source files** rather than machine-dependent install artifacts (e.g., `~/.claude/`). Installation paths vary by machine and operator role (servers + Macs + CI boxes); CI environments may not have `~/.claude/` at all. A test asserting on `~/.claude/commands/ready.md` would be non-hermetic (fails in CI) and environment-dependent; asserting on the source `harnesses/claude/commands/ready.md.j2` is hermetic (independent of install state). When testing generated artifacts (e.g., baked system prompts), assert on the **committed** baked files (e.g., `harnesses/claude/claude-shape-system-prompt.txt`), which are in-repo and CI-safe; they are generated at `make install` and checked in.

### Render-Check Test Pattern

New bash test files under `harnesses/claude/hooks/` are auto-discovered by `run-tests.sh` via `find *_test.sh` — no registration needed. When testing crash paths (e.g., render-check.js parse failures), use `make_render_stub` to create temp bash scripts for normal cases, but skip it for crash-path stubs: write garbage directly via `cat > stub <<'STUB' ... STUB` to produce output without `RENDER_VERDICT=` variable. Regression guard: `node --check` test in `render-check_test.sh` catches duplicate function definitions and parse errors early (cf. session 20260608_153448).

### Stub-Binary Test Pattern for Launchers

When testing launcher logic (e.g., cwd normalization in build launchers `claude-build.sh` / `pi-build.sh`), the test MUST stub the underlying binary that the launcher execs, NOT the agent binary (claude/pi). Build launchers exec `BUILD_BIN` (codegen-build), which is resolved via `OCG_CODEGEN_DIR` and `SCRIPT_DIR` — cwd-independent. Stub placement: create a temp directory with the binary named exactly `codegen-build` (the basename the launcher expects) and set `OCG_CODEGEN_DIR=stub_dir` to route `BUILD_BIN="${OCG_CODEGEN_DIR:+$OCG_CODEGEN_DIR/codegen-build}"` to the stub. Stub captures invocation args (write to file, exit 0) and assertions verify the launcher passed the correct args — e.g., the harness-appropriate pitch mention string (`@codegen/pitches/ready/<slug>.md` for claude, `codegen/pitches/ready/<slug>.md` for pi) — proving the launcher resolved paths correctly BEFORE exec. This pattern isolates launcher path logic from the full agent binary and keeps the test deterministic, enabling hermetic ExUnit execution without `@moduletag :slow`.

### Module-Attribute Data Loading via Code.eval_file

Data files can be loaded at **compile-time** (not test invocation) via `Code.eval_file/1` at module-attribute scope. Example: parity allowlist in `known_divergent.exs` ships as an empty Elixir list `[]`; loaded via `@allowlist Code.eval_file(Path.join(__DIR__, "known_divergent.exs")) |> elem(0)`. Evaluation happens once at module compilation, the result is bound to a compile-time constant `@allowlist`, and zero runtime I/O occurs on every test invocation. This pattern is appropriate for small, stable data files (e.g., divergence reasons, skip lists) that live alongside test modules.

### Bash Test Numbering Conventions

Hermetic bash test files (e.g., `prompt-content-parity_test.sh`) that use sequential test case numbering via inline comments (e.g., `# Test 1`, `# Test 2`) should renumber ALL such labels when new tests are added, to avoid duplicate numbers. When a test file carries comment headers like `# Test N:` to label each `assert_contains` or `assert_eq` block, adding a new test in the middle requires incrementing all subsequent test numbers to maintain clarity. Use this pattern for test clarity, but accept the bookkeeping cost — the numeric labels are documentation, not code-critical.

### Fixture Invalidation on Hook Logic Changes

When a hook's conditional logic widens (e.g., `agentType === "planner-phoenix"` → `agentType.startsWith("planner")`), existing test fixtures that rely on the literal condition falling through to an `else` branch become INVALID post-widen. They must be **converted**, not kept as-is.

**Example (session 20260613_planner-header-churn)**: `subagent-retrospective-guard.ts` had a fixture "enforces for planner-static" relying on the old `agentType === "planner-phoenix"` check falling through to an `else` branch. After widening to `agentType.startsWith("planner")`, the fixture's old header was never found, the hook silently skipped, and `stderr.includes("warning")` failed.

**Conversion pattern**: identify fixtures relying on the OLD condition falling through → rewrite to satisfy the NEW condition (same test name, new setup) — this is a required fix, not a new test.

**Critical**: when narrowing/widening hook logic, grep paired test file(s) for fixtures the change may invalidate; convert before landing or the suite emits false-positive passes (deny/block path never exercised, but assertion passes).

### Fixture and Build Patterns

- Tests scaffold a temp app, assert generated file contents, run `mix compile` or `npm run build` on output
- `last_green.json` is checked in — diff against it to spot regressions before merging
- Run a single test file: `mix test test/stacks/phoenix_test.exs` from `test_harness/`
- Async: most stack tests are synchronous (file system I/O)
- **ExUnit concurrency**: `max_cases` (default `System.schedulers_online() * 2`) governs how many test _modules_ run in parallel. Tests within a single module always run serially, regardless of `async: true`. To maximize concurrency, split fat modules into multiple `defmodule` blocks per file (each becomes an independent async unit). `test_harness/test/test_helper.exs` omits `:max_cases` override — the default is sufficient. Partition infrastructure (`--partitions 4`) was dropped in commit 9b09dc8 after splitting `test_harness/test/stacks/static/iteration_test.exs`, `test_harness/test/stacks/static/seed_test.exs`, `test_harness/test/stacks/static/scaffold_test.exs` into 14 modules; single `mix test` per harness now scales naturally.

## Deterministic Scaffold Testing vs. LLM-Driven Build Testing

**Two distinct test paths**:

1. **Deterministic scaffold variants** (e.g., `--no-ecto`): Use direct `codegen-scaffold` invocation via fixture helpers; no LLM involved. Validates scaffold output structure and compile correctness. Examples: `no_ecto_scaffold_test.exs` uses `run_no_ecto_scaffold/2`.
2. **LLM-driven builds**: Use `run_codegen_build/3` (harness launcher via JSONL stream). Validates LLM iteration patterns, commit messages, reviewer phase. Example: `scaffold_test.exs` via `run_codegen_build`.

**Fixture helper naming convention**: When a helper hardwires specific flags (e.g., `--no-ecto`), encode the flags in the function name for clarity:

- ✅ `run_no_ecto_scaffold/2` — signals this helper runs with `--no-ecto` fixed
- ❌ `run_codegen_scaffold/2` — too generic; doesn't signal fixed flags

Naming prevents accidental parameter overrides that would be silently ignored. Example:

```elixir
def run_no_ecto_scaffold(root_dir, app_name) do
  %{"NO_ECTO" => "1"}
  |> System.cmd(codegen-scaffold, ["create", "--stack=phoenix", "--cwd=#{root_dir}", "--slug=#{app_name}"], ...)
end
```

**Timeout guidance**: Deterministic scaffold runs (fixture setup only, no LLM) complete in seconds. Multi-phase LLM builds (scaffold + dev + review + commit) require 210+ seconds per iteration (deps.get 60s + compile 90s + LLM roundtrip 30-60s per phase).

**Fixture helper `run_codegen_call/3` baseline**: The fixture helper for testing ExUnit harness codegen_call invocations pre-wires `--model=#{model}` and `--effort=#{effort}` flags by resolving them from `config.yaml` via `config_yaml_read!`, not as assumptions or empty defaults. When debugging test failures related to `codegen-call` invocation, always Read the fixture helper to confirm what flags are already present before proposing additions — fixture claims in pitches may reflect pre-fix snapshots while the working tree has already resolved the issue.

## Fixture Isolation + Build Paths

`Fixtures.isolated_tmp_dir/1` creates separate temp directories for each harness test, with stack-specific config:

- `isolated_tmp_dir(stack: :phoenix)` — creates and pre-scaffolds a Phoenix app via `scaffold_phoenix_app!/1` before invoking harness
- `scaffold_phoenix_app!/1` runs `mix phx.new`, `mix deps.get`, and `git commit` in fixture setup, ensuring harness works on a real, git-tracked project
- Non-Phoenix stacks pass no `:stack` opt → directory is created empty (no scaffold pre-run)
- Both phoenix and non-phoenix variants initialize git (`git init` + initial commit) — fixtures are suitable for driving hooks directly via `System.cmd` that read git state or write the gate-result JSON

**Gate verdict parity**: Both phoenix and static stacks write the ephemeral gate-result JSON into `codegen/gate-pending/` via the `write_gate_result` shell fn (`gate-result.sh`). For non-interactive builds this is called from `LoopGate.run_gate/2`; for the interactive-session fallback the static stack's `static-site-build-check.sh` calls it directly. Test assertions mirroring the gate-result JSON schema are valid across stacks.

**Build path isolation**: Tests using `mix` with non-default `MIX_BUILD_PATH=_build/pi_test` (pi tests) require recompilation of fixture-modified files under BOTH the default and custom build paths. A stale `_build/pi_test` still serves old BEAM bytecode after fixture changes until that tree is recompiled. Solution: run `mix compile` after fixture code edits without the env var, then again with the env var set.

**Arity + BEAM**: Functions defined with default args (e.g., `def f(opts \\ [])`) export both arity-0 and arity-1 in BEAM. A stale `.beam` under a non-default build path silently serves old signatures until recompilation.

**Environment isolation**: `System.cmd/3` with `env: []` clears the entire process environment — stripping PATH, HOME, MIX_HOME, HEX_HOME. Safe only for git (reads repo-local config). Mix commands need ambient environment (`env: :inherit` or omit `:env` option).

**Parallel build-path isolation**: When running multiple independent test suites concurrently (e.g., `-j2` for `test-stacks-claude` and `test-stacks-pi`), each test harness must use a distinct `MIX_BUILD_PATH` to avoid BEAM artifact clobbering. Example: parity test uses `MIX_BUILD_PATH=_build/parity_test`, separate from the default `_build/claude_test` and `_build/pi_test` used by the per-harness stack suites. This ensures parallel `-j2` builds do NOT recompile over each other's artifacts.

Benchmark mode (BENCH=1), artifact layout, screenshot capture, mix viewer tasks: → see `context/test-benchmarking.md`.

## Pitfalls

- **Leaf test summary format is load-bearing** — `N passed, N failed` or `Results: N passed, N failed`. Preserve exact format per leaf; grep patterns require exact match.
- **Round-trip tests fail loud on missing tools** — require claude, jq, yq, rg, node on PATH; fail explicitly if absent.
- **`mix test` must be scoped** — bare `mix test` runs all tests; use file/tag filter (`--only phoenix`).
- **`last_green.json` is not auto-updated** — run `make record-green` explicitly after clean suite.
- **Hook tests are bash** — do not run via `mix test`; use `run-tests.sh`.
- **Gate-failure-path tests are `:slow`** — verdict != "clear" tests require real hooks; tag `:slow`, run only `make test-stacks`.
- **`mix assets.deploy` silent no-op risk** — guard assertions with filesystem checks (assets/ dir + alias in mix.exs).
- **Private helpers per-module only** — cannot share across modules in same file; promote to public support module or duplicate.
- **`phx_new` 1.8.7+ no `--force`** — scaffold via `mix phx.new . --app <name> --live` (no --force flag).
- **`run_with_timeout/4` return order** — returns `{output, exit_code}` (output-first); re-tuple explicitly if contract differs.
- **`assert_assets_deploy!` needs `MIX_ENV=dev`** — tailwind config is dev-only; pass `env: [{"MIX_ENV", "dev"}]` in System.cmd call.
- **`codegen-call` requires `--model`, `--effort`, `@<abs-path>`** — old API used exit 2; fixtures resolve from config.yaml, write temps, pass @/tmp/...
- **`default_spawn_fn/5` timeout kills whole child tree** — `Port.open`+receive-loop, not `Task.shutdown(:brutal_kill)` (orphans grandchildren). Seams: `:__queue_drain_build_bin__`, `:__queue_drain_kill_fn__`.
- **`bench_artifacts_test.exs` token list tracks screenshot.js changes** — update on Vite migration.

### Flake Triage Protocol

Apply to EVERY `make test-stacks` failure before touching source. Reference: `shared/recipes/flaky-test-fix.md` for pattern details.

**4 buckets:**

1. **Deterministic source bug** — same failure across 2+ runs, identical message; root cause in source. Fix source; confirm via `make test` + targeted `mix test <file> --only slow`.
2. **Deterministic test-vs-impl conflict** — assertion written against old API/behavior; impl changed, test didn't. Fix stale side; re-run.
3. **Genuine LLM flake** — non-determinism (missing PROJECT_CONTEXT.md, content markers, empty HTML, compile error). Confirm via 3× re-run; all pass → accept as flake. No retry infra, no widened assertions.
4. **Operational** — tool missing, bad creds, quota. Fix the precondition, not the test. Pi `gpt-5.3-codex-spark not supported` = account required, not a flake.

**Rules:**

- `--only slow` reporting "0 tests, exit 1" → tag/config problem (operational), not a flake.
- A flake with a deterministic root cause (race, stale assertion, nil guard) is bucket 1/2, not bucket 3 — fix it.
- NEVER mask a genuine flake with assertion widening or retry infra.
- Record confirmed flakes in session log: file:line, failure message, number of passes in re-runs.

## Hermetic Source-Text Regression Guards

Static source-ordering assertions (no runtime, no LLM) pinning invariant ordering in scripts. Pattern: extract file text → use `:binary.match/2` + stable substrings (not brittle full-line literals) to find byte-offsets → assert ordering/presence. Example: `screenshot.js` pre-warm guard asserts `index("mix deps.get") < index("waitForHttp200")`. Runs in `make test` (fast gate), fails loud with invariant message on reorder. Mirrors `render_check_test.exs` node-syntax model.

## Trigger Keywords

test_harness, test-stacks, last_green, record-green.sh, stack scaffold test, ExUnit assertions, role resolver, orchestration loop, mix codegen.loop, mix codegen.loop.queue, LoopGate, LoopQueue, LoopQueueDrain, claude-build --queue, pi-build --queue, flake triage, hermetic regression guards
