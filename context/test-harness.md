# Test Harness Domain — ExUnit Test Suite for Stacks

The test harness is an Elixir/ExUnit project in `test_harness/` validating scaffold output and stack behaviour end-to-end. Tests scaffold a fresh app, run generated code through real assertions, record a passing baseline in `last_green.json`. `record-green.sh` stamps the last known-good commit SHA for regression detection.

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
| `test_harness/lib/codegen_test_harness/role_resolver.ex`      | Resolves `{role, harness}` → `{model, effort}` via `config.yaml`; `resolve_harness/2` resolves the per-role harness override. Agent identity (system prompt, allowed tools) is NOT resolved here — claude_code invokes roles natively via `claude --agent <role>`. **Critical**: reads `.harness.<role>.<harness>.*` (e.g. `.harness.ops.claude.model`), NOT `.roles.<role>.*` (read by live launchers, e.g. `claude-ops.sh` reads `.roles.ops.model`) — distinct blocks. Hermetic tests in `role_resolver_test.exs`. |
| `test_harness/lib/codegen_test_harness/orchestration_loop.ex` | Deterministic cycle driver: sequences roles per stack, invokes each via `RoleResolver` → `codegen-call`, runs the gate via `LoopGate`. Hermetic tests in `orchestration_loop_test.exs`. |
| `test_harness/lib/codegen_test_harness/loop_gate.ex`          | Runs the gate as a loop step by shelling `gate-select.sh`/`gate-result.sh` — no gate-logic reimplementation.                                                                            |
| `test_harness/lib/codegen_test_harness/loop_queue.ex`         | Kahn topo-sort + transient-error classification; ported from removed `build-queue.sh`. Also parses `scope:` frontmatter (`parse_scope/2`, `scope_report/1`). See "Orchestration Loop" § below. Tests: `loop_queue_test.exs`. |
| `test_harness/lib/codegen_test_harness/loop_queue_drain.ex`   | Multi-pitch drain — `LoopQueue`'s live caller. See "Orchestration Loop" § below. Tests: `loop_queue_drain_test.exs`. |
| `test_harness/lib/mix/tasks/codegen.loop.ex`                  | `mix codegen.loop --harness=<claude_code\|pi> --stack=<phoenix\|static> --cwd=<dir> <pitch>` — entrypoint `dispatch.sh`'s build path execs.                                             |
| `test_harness/lib/mix/tasks/codegen.loop.queue.ex`            | `mix codegen.loop.queue --harness=<claude\|pi> --stack=<S> --cwd=<dir>` — wraps `LoopQueueDrain.drain/1`; invoked by `--queue` launcher flags. |
| `test_harness/lib/mix/tasks/codegen.pitches.scope.ex`         | `mix codegen.pitches.scope [--dir=ready\|draft\|shipped] [--cwd=<dir>]` — read-only COLLISIONS/DISJOINT/UNROUTED report over `LoopQueue.scope_report/1`. No gate, no partitioning. Tests: `codegen_pitches_scope_test.exs`. |
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

Deterministic Elixir replacement for the removed self-orchestrating harness session — `codegen-build` has no engine flag; `dispatch.sh` (both harnesses) always execs `mix codegen.loop`. Shared ExUnit helpers (`run_codegen_build/3`, `run_codegen_build_parity/4` in `fixtures.ex`) call `codegen-build` with `--harness`/`--stack`/`--cwd` only.

- `OrchestrationLoop.role_sequence/1` — Phoenix plan-first; static developer-first.
- `OrchestrationLoop.run/1` — sequences roles via `invoke_role/4` (real `RoleResolver.resolve_role/2` → `codegen-call`), interleaves `LoopGate.run_gate/2` after the developer role. Envelope `result.status`: `"success"` advances, `"failed"` retries SAME role once then `{:error, reason}`; other shapes RAISE. Gate verdict BINARY (`:clear|:failed`); RAISES on stray verdict. `stack: "static"` runs `:preflight_fn` before gate — RAISES naming missing dep (node/render-check.js/chromium). Phoenix skips preflight.
- **Per-role harness** — `RoleResolver.resolve_harness/2` reads optional `.harness.<role>.harness` (`claude_code`/`pi`) in `config.yaml`, else build's `--harness`. Resolved at 3 chokepoints: `invoke_role/4`, `maybe_escalate_model/5`, `handle_switch_model_failure/7`.
- **Reviewer→dev fix cycle** — reviewer ends with `REVIEW_VERDICT: APPROVED|CHANGES_REQUESTED`. `CHANGES_REQUESTED` re-invokes dev with feedback, re-formats, re-gates, re-reviews (within `:max_review_cycles`, default 1).
- **Committer verification** (`verify_committed!/1`) — post-commit TAIL guard: asserts `git status --porcelain` empty (dirty RAISES) AND `assert_work_produced!/2` requires `rev-list --count base..HEAD == 1` (0=no-op, ≥2=split commits, both RAISE) with non-empty diff, THEN `assert_base_not_orphaned!/2` asserts `merge-base --is-ancestor base HEAD` (nonzero = `base` dropped via `git reset` — RAISES). No-op on non-git cwd. Amend-safe.
- **Turn-0 clean-tree precondition** (`preflight_clean_tree!/1`) — HEAD guard symmetric to the tail guard above: `run/1` asserts porcelain-empty BEFORE any role/gate. Dirty at start RAISES (no auto-stash). Overridable via `:clean_tree_preflight_fn` for tests pre-seeding dirty state to simulate mid-cycle output.
- **Cwd-threaded calls** — `invoke_role/4`'s default `codegen_call_fn` closes over `ctx.cwd` AND `role`, calls `default_codegen_call/9` (cwd first arg, transcript + agent trailing args, `System.cmd(cd: cwd)`) so each role's agent runs IN the project dir with native `--agent <role>` identity. Test seam stays `/6`.
- **Per-role transcript capture (optional)** — `mix codegen.loop` derives `cycle_id="<stamp>_<slug>"` (single-pitch entry; queue inherits via child subprocess), threads into `run(cycle_id: ...)`. `invoke_role/4` computes `transcript_path/4` = `<cwd>/codegen/logging/<cycle_id>/NN-<role>.jsonl` (nil cycle_id → nil, no-op) → `CODEGEN_CALL_TRANSCRIPT_PATH` env; both `call-dispatch.sh` copy their temp stream-json there on EXIT (fail-loud-non-blocking). `write_cycle_summary/6` appends `{role,seq,num_turns,cost_usd,status,transcript}` per invocation to `cycle-summary.jsonl` in the same dir. Gitignored.
- **Telemetry** — `accumulate_telemetry/2` sums each envelope's `usage` (cost/tokens/turns) into a process-dict accumulator (`get_telemetry/0`/`zero_telemetry/0`) per role, across all invocations incl. retries. `Mix.Tasks.Codegen.Loop.emit_loop_telemetry/1` prints one aggregated `{"type":"result",...}` JSON line after `run/1` regardless of outcome, for the benchmark harness.
- **Gate selection** (`LoopGate.decide_gate/1`, `gate-select.sh`) — 2-source tree: (1) planner Tier-1 `**Gate**:` block (JSONL parsed), wins over (2) per-app `.claude/gate-config.sh` `GATE_COMMAND=<cmd>`. Falls back fail-loud `__GATE_UNRESOLVED__` (raises). Static tests MUST supply GATE_COMMAND config or planner step_log to resolve gate; no stack-default fallback exists post-refactor.
- **`call-dispatch.sh` flip** — `codegen-call --agent <role>` exports `CODEGEN_CALL_AGENT`; `harnesses/claude/call-dispatch.sh` reads it and, when non-empty, appends `--agent "$AGENT"` and OMITS `--append-system-prompt` (native agent identity replaces the appended prompt). Pi's `call-dispatch.sh` is unaffected (unread env var; pi has no `--agent` concept).
- `guard_bundle_flag!("claude_code")` now defaults to the FULL committed `harnesses/claude/claude-code-settings.json` — the same file the legacy (non-loop) path loads. See `context/core.md` § Loop Role Invocation.
- Test seams: `:invoke_fn`, `:gate_fn`, `:gate_preflight_fn`, `:advance_cycle_state_fn`, and (on `invoke_role/4`) `:resolve_fn`/`:codegen_call_fn` opts let tests stub the LLM/gate/state-write entirely. Use `Keyword.merge(defaults, extra)` NOT `list1 ++ list2` when merging `_fn` opts (left wins in concat, right wins in merge). **Race convention**: Any `async: true` test using the shared literal `cwd: "/tmp/irrelevant"` that can reach `:clear` gate (via `always_clear_gate_fn()` or custom gate_fn) MUST stub `:advance_cycle_state_fn` to a no-op to prevent concurrent tests from racing on `mkdir -p "$cwd/codegen/gate-pending"`. Alternatively, use per-test unique tmpdir. See `orchestration_loop_test.exs` `no_op_advance_cycle_state_fn/0` helper for pattern.
- `LoopGate.run_gate/2` shells `gate-select.sh`/`gate-result.sh` — reuses `codegen/gate-pending/` JSON schema unchanged.
- **Turn-0 gate preflight** (`preflight_gate!/2`) — `run/1` resolves the app gate via `:gate_preflight_fn` (default `LoopGate.decide_gate/1`) BEFORE `run_roles`, i.e. before any role is invoked or paid for. Resolution-only (never executes the gate). An unresolvable gate (missing/empty/stale `GATE_COMMAND` in `.claude/gate-config.sh`) raises at turn 0 with an actionable "add GATE_COMMAND or re-integrate" message, instead of crashing mid-cycle after the developer role. The real gate still resolves+executes later in `do_gate_loop`; the preflight is additive, its value is timing.
- **Turn-0 role-agent resolution preflight** (`preflight_roles!/3`) — `run/1` confirms every role in the resolved sequence resolves as an installed `--agent` BEFORE any role is invoked, via `:preflight_probe_fn` (default `default_preflight_probe/1`: sentinel `codegen-call --agent __codegen_loop_preflight_probe__` — claude exits 1 immediately with `Available agents: <csv>`, zero model turns). `missing = roles -- available` non-empty → raises naming missing roles + available + `make install` hint. No parseable line → raises (fail-closed). Prevents a broken role set surfacing mid-cycle as a mis-labeled transient retry. Tests: `orchestration_loop_test.exs` describe "turn-0 role-agent resolution preflight".
- **Warm-resume on transient retry** (`do_invoke_attempt/6`, `invoke_role/4`, `resume_prompt/1`) — transient failure resumes the SAME session (mint via `mint_session_id/0`, short continuation prompt). `stale_session_reason?/1` falls back cold. `CODEGEN_RESUME_ATTEMPT=<sid>` treats new token as fresh-run not spin.
- **Cycle-level resume** (`resume_checkpoint/3`) — turn-0 check for durable checkpoint (state ∈ {GATED, REVIEWED, CURATED} + gate clear + tree match + HEAD unmoved). Valid → resume at mapped role, skipping expensive prefix; invalid → `:full`. Seams: `:cycle_state_get_fn`, `:read_verdict_fn`, `:gate_tree_match_fn`, `:gate_result_base_sha_fn`, `:log_resume_fn`. Tests: "resume-checkpoint".
- **Single-pitch move** — `Mix.Tasks.Codegen.Loop.run/1` is the primary shipper in BOTH modes (`--queue` spawns a solo `mix codegen.loop` child on a `ready/` pitch). `verify_commit_landed/2` returns `{:ok, after_sha | nil}` (was bare `:ok`); `maybe_ship_pitch/4` (`source, cwd, before_sha, after_sha`) moves `ready/<slug>.md` → `shipped/<slug>.md`, calling `LoopQueue.record_ship/4` first — writes a `refs/notes/pitches` note, THEN `shipped_sha:`/`shipped_range:` frontmatter (note-first: a died-before-frontmatter failure never strands an already-shipped stamp the next build's `@`-mention would misread). Fails open on non-git/nil sha. `LoopQueueDrain.ship/3` (now 6-arity) is the FALLBACK. Tests: `codegen_loop_test.exs`, `loop_queue_test.exs` describe "record_ship/4".
- `LoopQueue` mirrors `retryable_regex` transient and Kahn topo-sort. `LoopQueueDrain.drain/1` is the sole `--queue` drainer: `claude-build.sh`/`pi-build.sh --queue` always execs `mix codegen.loop.queue`. Shares `codegen/gate-pending/` lock with single-pitch builds. Operator output: per-pitch banner, two-path echo (`_cycle.jsonl`+`_build.log`, fail-open), streamed stderr, terminal outcomes; `_build.log` pruned >7d at leg-1. Tests: `loop_queue_drain_test.exs`. Per-pitch child: `default_spawn_fn/5` invokes `codegen-build --harness=<h> --stack=<s> --cwd=<c> -- <pitch>`.
- **Committed-but-nonzero recovery** — `handle_nonzero_exit/7` detects committer-post-commit hiccup (HEAD moved + gate `"clear"` + fresh), counts pitch shipped instead of erroring. `committed?` forward-only (`head_before` must be an ancestor of new HEAD, via `:git_ancestor_fn`); non-descendant move halts loud with `git rebase --onto` remediation, pitch left `ready/`. Tests: `loop_queue_drain_test.exs` (`6r1`-`6r6`, `6r-orphan`, `6r-forward`, `6r-fresh-*`).
  - **Idempotency contract**: `LoopQueueDrain.ship/3` MUST be idempotent (`:ok` if dst exists) — the solo child usually ships first via `maybe_ship_pitch/4`; drain never fights it for ownership.
- **Gate-record freshness** — `LoopGate` writes `base_sha` = short HEAD at gate time (`""` if non-git); gate runs BEFORE committer, so sha only ever prefixes `head_before`, never post-commit `head_after`. `gate_fresh?/3` also requires gate mtime `>=` spawn `ts`, rejecting a stale verdict from an earlier non-committing cycle sharing the same base. Tests: `loop_gate_test.exs`.
- **Gate content binding** — `base_sha` pins HEAD only, not content. `LoopGate` also stamps `graded_tree_sha` (git tree object, temp-index refreshed; else `HEAD^{tree}`). `ensure_gate_graded_this_tree!/5` re-compares stamped vs. current tree before commit; mismatch re-gates (bounded `:max_final_gate_cycles`, default 1). `assert_commit_matches_gate!/1` re-checks post-commit. `""` either side → skip. Tests: `loop_gate_test.exs`/`orchestration_loop_test.exs`.
- **Turn-0 orientation-doc preflight** (`preflight_orientation_docs!/2`) — after `preflight_roles!/3`. Shells index-parity + factcheck (codegen sentinel). Inherited violation → `InfraAbort` (exit 3, pitch stays `ready/`), not a paid cycle dying at `run_curator_doc_check`. Tests: describe "turn-0 orientation-doc preflight".
- **Repair loops (`repair_allowed?/4`), floor-then-progress-bounded**: `:max_curator_doc_cycles`/`:max_env_var_cycles` are a floor; beyond it, a rework is granted only if a prior violation resolved, capped by `@repair_progress_ceiling` (15). Tests: `orchestration_loop_test.exs`.
- **Deterministic failure handling**: pitch stays `ready/`, tree stashed to `queue-fail/<slug>/<ts>` branch (fail-open, no invisible stash). Timeout stash restored before retry; fail stash never auto-restored. Circuit breaker `:max_consecutive_fails` (default 3) HALTs on threshold. Tests: `loop_queue_drain_test.exs`.
- State advancement (GATED→REVIEWED→CURATED→COMMITTED) shells `cycle-state.sh` via `advance_cycle_state_step/3`.
- **Cutover complete**: in-harness self-orchestration + legacy shell queue drainer DELETED — `LoopQueueDrain` is the sole `--queue` engine. `codegen-build` has no engine flag; the Elixir loop is unconditional for single-pitch and `--queue` builds.
- **`--watch`** (`--queue --watch`): empty `ready/` sleeps (`CODEGEN_BUILD_QUEUE_POLL_SECS`, default 60) + re-scans instead of returning; other exits unchanged. Quiescence gate (`CODEGEN_BUILD_QUEUE_QUIESCE_SECS`, default 30, via `:mtime_fn`) excludes a mid-`scp` pitch from `ordered_fn`/`blocked_fn` BEFORE they run (`LoopQueue.*` `exclude` param). Darwin: `:keychain_fn` pre-spawn check (fail-closed) + `caffeinate -dimsu` guard the Keychain-sleep failure. Tests: `loop_queue_drain_test.exs` "`:watch`" describes.
- **Pitch-path resolution contract** — `dispatch.sh` runs `cd "$LOOP_DIR"` (`$LOOP_DIR` = `<repo>/test_harness/`) before execing `mix codegen.loop`. Any mix task resolving a relative file path (pitch arg, draft slug) MUST join it against the explicit `--cwd` flag (the real project root), never `File.cwd!()`. Pattern: `Path.expand(relative_path, cwd)`. Applies to any future mix task accepting a file-path arg.
- **`build_prompt/2` testability & reviewer file set** — Prompt-assembly point in `OrchestrationLoop.build_prompt(role, ctx)`. `def`+`@doc false` for direct ExUnit calls. Reviewer branch renders loop-derived `## Files Modified` list (`invoke_reviewer/4` → `default_review_file_set_fn/1`, mirrors `default_rework_brief_fn/1`'s git idiom); content via `git diff HEAD -- <path>`. Empty set in real git tree → loop refuses reviewer invoke. Gate-clear drops `:last_failure_reason` — no stale leak into reviewer prompt.

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

Assertion helpers defined in `CodegenTestHarness.Assertions` should be wired into test cases guarding important postconditions (e.g., `assert_assets_deploy!`, `assert_generated_tests_pass!`). Undefined helpers with zero call sites represent regression gaps. **Static scaffold outDir**: Vite sets `outDir: "public"` (not `dist/`). Assertions must expect `public/` not `dist/`.

Bash hook test debugging (silent crashes, early exits) → `context/hooks.md`. npm extension parallel-race flake → `context/test-harness-pitfalls.md`.

## Hermetic Regression Guards

Two new test files in `test_harness/test/codegen_test_harness/` run under `make test-hermetic` (do NOT carry `@moduletag :slow`; only hermetic tests):

- **`render_check_test.exs`** — Validates `harnesses/claude/hooks/lib/render-check.js` syntax correctness via `node --check` on both render-check.js and phoenix-server.js. Smoke-invokes `render-check.js` asserting a `RENDER_VERDICT=` line emits (catches silent parse failures). Skips-with-reason if `node` absent (browserless box allowed). Critical for catching render-check regressions without requiring a full LLM gate cycle.
- **`call_contract_test.exs`** — Asserts the harness-name mapping: `Fixtures.codegen_call_harness/0` returns `"claude_code"` (codegen-call harness name), not `"claude"` (codegen-build harness name). Catches class-2 regressions where fixture feeds wrong harness ID to the call binary.

### Hermetic Role-Absent Testing Pattern for codegen-call

`Fixtures.run_codegen_call/3` derives `--model` and `--effort` flags from `config.yaml` by role → a **real role string is required**. This helper cannot serve as a test vehicle for role-absent cases. Instead, hermetic role-absent tests trigger via a **different missing argument** (e.g., `--harness`) that causes exit 2 with usage text, then assert the usage message is emitted. Pattern: `System.cmd("codegen-call", [missing args that trigger exit 2], ...)` and `assert {_, 2} = result`, then inspect stdout for usage text mentioning `--harness`. This approach validates the role-optional behavior without requiring dispatch through the role-resolution path.

For full make-target index including install/uninstall/CI targets, see `context/development.md`.

## Integration Points

- **scaffold**: tests exercise `shared/scaffold/<stack>/scaffold.sh` output — scaffold changes require test updates; see `context/scaffold.md`
- **core**: `generate.sh` output (rendered agent files) may be asserted against in tests
- **development**: `make test-stacks` runs the ExUnit suite; `make record-green` stamps last_green after CI passes; see `context/development.md` for full make-target index
- **hooks**: hook bash tests (`*_test.sh`) are separate — run via `harnesses/claude/hooks/run-tests.sh`, not `mix test`; see `context/hooks.md`

Seam threading (preserving test-override capacity when adding new fn params) + RoleResolver shape-change ripple to sibling tests → `context/test-harness-pitfalls.md`. Fixture/flake/Ecto/Port gotchas that overflow this file also live there.

## Testing Patterns

### Hermetic Bash Test Assertion Pattern

Hermetic bash tests (e.g., `*_test.sh` hook tests) should assert on **committed, in-repo source files** rather than machine-dependent install artifacts (e.g., `~/.claude/`). Installation paths vary by machine and operator role (servers + Macs + CI boxes); CI environments may not have `~/.claude/` at all. A test asserting on `~/.claude/commands/ready.md` would be non-hermetic (fails in CI) and environment-dependent; asserting on the source `harnesses/claude/commands/ready.md.j2` is hermetic (independent of install state). When testing generated artifacts (e.g., baked system prompts), assert on the **committed** baked files (e.g., `harnesses/claude/claude-shape-system-prompt.txt`), which are in-repo and CI-safe; they are generated at `make install` and checked in.

### Render-Check Test Pattern

New bash test files under `harnesses/claude/hooks/` are auto-discovered by `run-tests.sh` via `find *_test.sh` — no registration needed. When testing crash paths (e.g., render-check.js parse failures), use `make_render_stub` to create temp bash scripts for normal cases, but skip it for crash-path stubs: write garbage directly via `cat > stub <<'STUB' ... STUB` to produce output without `RENDER_VERDICT=` variable. Regression guard: `node --check` test in `render-check_test.sh` catches duplicate function definitions and parse errors early (cf. session 20260608_153448).

### Stub-Binary Test Pattern for Launchers

When testing launcher logic (e.g., cwd normalization in build launchers `claude-build.sh` / `pi-build.sh`), stub the underlying binary the launcher execs (`BUILD_BIN`=codegen-build, resolved via `OCG_CODEGEN_DIR`/`SCRIPT_DIR`, cwd-independent) — NOT the agent binary. Stub: temp dir, binary named `codegen-build`, `OCG_CODEGEN_DIR=stub_dir`; captures invocation args, exits 0. Assertions verify correct args (e.g. harness-appropriate pitch mention: `@codegen/pitches/ready/<slug>.md` claude vs `codegen/pitches/ready/<slug>.md` pi) before exec. Isolates launcher path logic, hermetic, no `@moduletag :slow`.

### Module-Attribute Data Loading via Code.eval_file

Data files can be loaded at **compile-time** (not test invocation) via `Code.eval_file/1` at module-attribute scope. Example: parity allowlist in `known_divergent.exs` ships as an empty Elixir list `[]`; loaded via `@allowlist Code.eval_file(Path.join(__DIR__, "known_divergent.exs")) |> elem(0)`. Evaluation happens once at module compilation, the result is bound to a compile-time constant `@allowlist`, and zero runtime I/O occurs on every test invocation. This pattern is appropriate for small, stable data files (e.g., divergence reasons, skip lists) that live alongside test modules.

### Bash Test Numbering Conventions

Hermetic bash test files (e.g., `prompt-content-parity_test.sh`) using sequential `# Test N` comment labels should renumber ALL labels when a new test is inserted mid-file, to avoid duplicates. Bookkeeping cost accepted — labels are documentation, not code-critical.

### Fixture Invalidation on Hook Logic Changes

When a hook's conditional logic widens (e.g., exact-match → `startsWith`), fixtures relying on the literal condition falling through to an `else` branch become INVALID post-widen — must be **converted**, not kept as-is. Example: a fixture relied on old exact-match falling through; after widening, its header was never found and the hook silently skipped. **Critical**: when narrowing/widening hook logic, grep paired test file(s) for fixtures the change may invalidate; convert before landing.

### Test Mock Anti-Pattern: Encoding the Prod Bug

A test fixture can encode the SAME false premise as the prod bug it should catch — suite stays green through regressions. Example: a mock returned post-commit HEAD where the real gate only ever writes pre-commit HEAD. **Fix**: re-model the fixture correctly + add producer/consumer reconciliation tests running the REAL producer against the REAL consumer's predicate.

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

**Timeouts**: Deterministic scaffold (fixture setup only) seconds. Multi-phase LLM builds (scaffold + dev + review + commit) 210+ sec/iteration (deps.get 60s + compile 90s + LLM roundtrip 30-60s). **Fixture flags**: `run_codegen_call/3` pre-wires `--model`/`--effort` by resolving from `config.yaml` via `config_yaml_read!`, never as empty defaults; always Read helpers to confirm what flags are baked before proposing additions.

## Fixture Isolation + Build Paths

`Fixtures.isolated_tmp_dir/1` creates separate temp directories for each harness test, with stack-specific config:

- `isolated_tmp_dir(stack: :phoenix)` — creates and pre-scaffolds a Phoenix app via `scaffold_phoenix_app!/1` before invoking harness
- `scaffold_phoenix_app!/1` delegates to `codegen-scaffold create` (not raw `mix phx.new`) — base fixture carries `make ci` toolchain for the loop gate
- Non-Phoenix stacks pass no `:stack` opt → directory is created empty (no scaffold pre-run)
- Both phoenix and non-phoenix variants initialize git (`git init` + initial commit) — fixtures are suitable for driving hooks directly via `System.cmd` that read git state or write the gate-result JSON

**Gate verdict parity**: Both phoenix and static stacks write the ephemeral gate-result JSON into `codegen/gate-pending/` via the `write_gate_result` shell fn (`gate-result.sh`), called from `LoopGate.run_gate/2` — the sole build engine (no separate interactive-session fallback path or caller exists). Test assertions mirroring the gate-result JSON schema are valid across stacks.

**Build path isolation**: Tests using `mix` with non-default `MIX_BUILD_PATH=_build/pi_test` (pi tests) require recompilation of fixture-modified files under BOTH the default and custom build paths. A stale `_build/pi_test` still serves old BEAM bytecode after fixture changes until that tree is recompiled. Solution: run `mix compile` after fixture code edits without the env var, then again with the env var set.

**Arity + BEAM**: Functions defined with default args (e.g., `def f(opts \\ [])`) export both arity-0 and arity-1 in BEAM. A stale `.beam` under a non-default build path silently serves old signatures until recompilation.

**Environment isolation**: `System.cmd/3` with `env: []` clears the entire process environment — stripping PATH, HOME, MIX_HOME, HEX_HOME. Safe only for git (reads repo-local config). Mix commands need ambient environment (`env: :inherit` or omit `:env` option).

**Parallel build-path isolation**: concurrent suites (e.g. `-j2` `test-stacks-claude`/`test-stacks-pi`) need distinct `MIX_BUILD_PATH` to avoid BEAM artifact clobbering — parity test uses `_build/parity_test`, separate from `_build/claude_test`/`_build/pi_test`.

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

## Trigger Keywords

test_harness, test-stacks, last_green, record-green.sh, stack scaffold test, ExUnit assertions, role resolver, orchestration loop, mix codegen.loop, mix codegen.loop.queue, mix codegen.pitches.scope, LoopGate, LoopQueue, LoopQueueDrain, claude-build --queue, pi-build --queue, flake triage, hermetic regression guards, scope: frontmatter
