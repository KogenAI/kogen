# Test Harness Domain — ExUnit Test Suite for Stacks

The test harness is an Elixir/ExUnit project in `test_harness/` validating scaffold output end-to-end. Tests scaffold a fresh app, run generated code through real assertions, record a passing baseline in `last_green.json`. `record-green.sh` stamps the last known-good commit SHA for regression detection.

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
| `test_harness/lib/codegen_test_harness/orchestration_loop.ex` | Deterministic cycle driver — contract → `context/loop.md`. Tests in `orchestration_loop_test.exs`. |
| `test_harness/lib/codegen_test_harness/loop_gate.ex`          | Runs the gate as a loop step via `gate-select.sh`/`gate-result.sh` (no gate-logic reimpl).                                                                                              |
| `test_harness/lib/codegen_test_harness/loop_queue.ex`         | Kahn topo-sort + transient-error classification; ported from removed `build-queue.sh`. Parses `scope:` (`parse_scope/2`, `scope_report/1`); folds into lanes via `partition/2`, or fleet-safe via `fleet_partition/3` (see `context/deployment-topology.md`). Parses/reconciles `handoffs:` (`parse_handoffs/2`, `handoff_receipt/2`, `reconcile_handoffs/4`, `write_handoff_receipt!/3` — `context/pitch-lifecycle.md`). See "Orchestration Loop" § below. Tests: `loop_queue_test.exs`. |
| `test_harness/lib/codegen_test_harness/loop_queue_drain.ex`   | Multi-pitch drain — `LoopQueue`'s live caller. See "Orchestration Loop" § below. Tests: `loop_queue_drain_test.exs`. |
| `test_harness/lib/mix/tasks/codegen.loop.ex`                  | `mix codegen.loop --harness=<claude_code\|pi> --stack=<phoenix\|static> --cwd=<dir> <pitch>` — entrypoint `dispatch.sh`'s build path execs.                                             |
| `test_harness/lib/mix/tasks/codegen.loop.queue.ex`            | `mix codegen.loop.queue --harness=<claude\|pi> --stack=<S> --cwd=<dir>` — wraps `LoopQueueDrain.drain/1`; invoked by `--queue` launcher flags. |
| `test_harness/lib/mix/tasks/codegen.pitches.scope.ex`         | `mix codegen.pitches.scope [--dir=ready\|draft\|shipped] [--cwd=<dir>] [--lanes=N] [--check] [--slug=<s>] [--stamp-handoff-receipt]`. Report default. `--check` gates `make test` (pitch-scope-parity), non-zero on UNROUTED/SUBSUMED/(with `--slug`) HANDOFF GAP. Tests: `codegen_pitches_scope_test.exs`. |
| `test_harness/record-green.sh`                                | Records commit SHA + timestamp to `last_green.json`; `--auto-commit` for scoped fail-soft commit |
| `test_harness/last_green.json`                                | Baseline: last commit SHA where full test suite passed |
| `test_harness/test/harness_parity/pi_parity_test.exs`         | Cross-harness build parity tests (claude vs pi); tagged `@moduletag :harness_parity` |
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
| `iteration_test.exs`                                  | Multi-step iteration/cycle continuity (Phoenix); multi-step static site iteration (Static)       | Phoenix, Static          |
| `scaffold_test.exs`                                   | Scaffold template rendering and output correctness                                              | Phoenix                 |
| `seed_test.exs`                                       | Database seed lifecycle and reproducibility                                                     | Phoenix                 |
| `test_harness/test/stacks/modes/debug_test.exs`       | Asserts debug launcher emits diagnostic report + writes no files                                | Debug (claude + pi)     |
| `test_harness/test/stacks/modes/shape_test.exs`       | Asserts shape launcher produces/edits draft pitch with Shape Up sections                        | Shape (claude + pi)     |
| `test_harness/test/harness_parity/pi_parity_test.exs` | Cross-harness parity: phoenix-minimal, static-minimal (claude vs pi). Tagged `:harness_parity`. | Parity (both harnesses) |

## Orchestration Loop Test Coverage (`OrchestrationLoop`/`LoopGate`/`LoopQueue`/`LoopQueueDrain`)

**The engine's own contract (module map, decider map, budget cap, escalation, resume, signals) is owned
by `context/loop.md` and `context/loop-queue-drain.md`; gate verdict truth table + cycle-log schema by
`context/cycle-record.md`.** This section documents ExUnit-suite implementation detail (test seams,
race conventions, fixture patterns) — not the loop's own domain contract.

`codegen-build` has no engine flag; `dispatch.sh` always runs `mix codegen.loop` (job-controlled, non-exec, via shared `loop-signal-bridge.sh`). Shared ExUnit helpers (`run_codegen_build/3`, `run_codegen_build_parity/4` in `fixtures.ex`) call `codegen-build` with `--harness`/`--stack`/`--cwd` only.

- `OrchestrationLoop.role_sequence/1` — Phoenix plan-first, static dev-first.
- `OrchestrationLoop.run/1` — sequences roles via `invoke_role/4` (real `RoleResolver.resolve_role/2` → `codegen-call`), interleaves `LoopGate.run_gate/2` after the developer role. Envelope `result.status`: `"success"` advances, `"failed"` retries SAME role once then `{:error, reason}`; other shapes RAISE. Gate verdict BINARY (`:clear|:failed`); RAISES on stray verdict. `stack: "static"` runs `:preflight_fn` before gate — RAISES naming missing dep (node/render-check.js/chromium). Phoenix skips preflight.
- **Per-role harness** — `RoleResolver.resolve_harness/2` reads optional `.harness.<role>.harness` (`claude_code`/`pi`) in `config.yaml`, else build's `--harness`. Resolved at 3 chokepoints: `invoke_role/4`, `maybe_escalate_model/5`, `handle_switch_model_failure/7`.
- **Reviewer→dev fix cycle** — reviewer ends with `REVIEW_VERDICT: APPROVED|CHANGES_REQUESTED`. `CHANGES_REQUESTED` re-invokes dev, re-formats, re-gates, re-reviews (within `:max_review_cycles`, default 1). `parse_review_verdict/1`: authored contract stays one bare terminal line; parser also tolerates that line wrapped once in one exact `**…**` pair (sole recovery wrapper) — gated on uniqueness (`contains?` scan) + terminality before classifying; else `:unknown`.
- **Committer verification** (`verify_committed!/1`) — post-commit TAIL guard: asserts `git status --porcelain` empty (dirty RAISES) AND `assert_work_produced!/2` requires `rev-list --count base..HEAD == 1` (0=no-op, ≥2=split commits, both RAISE) with non-empty diff, THEN `assert_base_not_orphaned!/2` asserts `merge-base --is-ancestor base HEAD` (nonzero = `base` dropped via `git reset` — RAISES). No-op on non-git cwd. Amend-safe.
- **Turn-0 clean-tree precondition** (`preflight_clean_tree!/1`) — HEAD guard symmetric to the tail guard above: `run/1` asserts porcelain-empty BEFORE any role/gate. Dirty at start RAISES (no auto-stash). Overridable via `:clean_tree_preflight_fn` for tests pre-seeding dirty state to simulate mid-cycle output.
- **Cwd-threaded calls** — `invoke_role/4`'s default `codegen_call_fn` closes over `ctx.cwd`+`role`, calls `default_codegen_call/9` (`System.cmd(cd: cwd)`) so each role's agent runs IN the project dir with native `--agent <role>` identity. Test seam stays `/6`.
- **Per-role transcript capture (optional)** — `mix codegen.loop` derives `cycle_id="<stamp>_<slug>"` (single-pitch entry; queue inherits via child subprocess), threads into `run(cycle_id: ...)`. `invoke_role/4` computes `transcript_path/4` = `<cwd>/codegen/logging/<cycle_id>/NN-<role>.jsonl` (nil cycle_id → nil, no-op) → `CODEGEN_CALL_TRANSCRIPT_PATH` env; both `call-dispatch.sh` copy temp stream-json there on EXIT (fail-loud-non-blocking). `write_cycle_summary/6` appends `{role,seq,num_turns,cost_usd,status,transcript}` per invocation. Gitignored.
- **Telemetry** — `accumulate_telemetry/3` (`/2` delegates) sums `usage` per role incl. retries; 3rd arg dispatch map now `%{harness,model,effort,source,native_effort}` (`source`: `:role_config`|`:build_override`|`:escalation`|`:campaign`; `native_effort` = adapter-realized control via `native_effort_realization/2`). `UsageParser.parse_dispatches/1` reads it; `emit_loop_telemetry/1` prints one line after `run/1`. Campaign binding → `context/loop.md`.
- **`opts[:effort_override]`** (`invoke_role/4`, from `codegen-build --effort=<e>`) — fixed campaign binding wins; else REPLACES resolved effort (model unchanged) over `resolve_fn` or an in-progress escalation/fallback rung. Absent → `source: :role_config`, unchanged.
- **Gate selection** (`LoopGate.decide_gate/1`, `gate-select.sh`) — ONE source: the per-app `.claude/gate-config.sh` `GATE_COMMAND=<cmd>`. Falls back fail-loud `__GATE_UNRESOLVED__`. Every test MUST supply GATE_COMMAND; no stack-default fallback and no per-cycle override. Mode/timeout are derived from the command string unless the config declares `GATE_MODE`/`GATE_TIMEOUT`, which are optional, taken verbatim, and fail loud when malformed. Note the derived timeout is 0 for any command the heuristics do not recognise (codegen's own `make test` included) — `run_with_deadline/4` floors a 0 to `@default_short_gate_timeout` (900s), so 0 means "no budget declared", never "no budget".
- **`call-dispatch.sh` flip** — `codegen-call --agent <role>` exports `CODEGEN_CALL_AGENT`; `harnesses/claude/call-dispatch.sh` reads it, appends `--agent "$AGENT"`, OMITS `--append-system-prompt` (native agent identity replaces it). Pi's `call-dispatch.sh` is unaffected (no `--agent` concept).
- `guard_bundle_flag!("claude_code")` defaults to the FULL committed `harnesses/claude/claude-code-settings.json` — same file the legacy path loads. See `context/core.md` § Loop Role Invocation.
- Test seams: `:invoke_fn`, `:gate_fn`, `:gate_preflight_fn`, `:advance_cycle_state_fn`, and (on `invoke_role/4`) `:resolve_fn`/`:codegen_call_fn` stub the LLM/gate/state-write entirely. Use `Keyword.merge(defaults, extra)` NOT `list1 ++ list2` (right wins in merge). **Race convention**: an `async: true` test sharing `cwd: "/tmp/irrelevant"` that can reach `:clear` gate MUST stub `:advance_cycle_state_fn` to a no-op (prevents concurrent `mkdir -p` races) — or use a per-test unique tmpdir.
- **Owner-routing/flake/marker seams** — `:gate_classify_fn` is 2-arity (`(cwd, dev_role) -> {:owner, role} | :infra | :stale_build`). `:flake_check_fn` (default `:gate_fn`) backs one flake re-run before rework. `:stale_build_heal_fn` (default: nukes `_build`) backs `:stale_build` — one rebuild + gate re-run (attempt not spent), else owner rework. Drain's `:terminal_marker_fn` reads `terminal-state.json`.
- `LoopGate.run_gate/2` shells `gate-select.sh`/`gate-result.sh` — reuses `codegen/gate-pending/` JSON schema unchanged.
- **Turn-0 gate preflight** (`preflight_gate!/2`) — `run/1` resolves the app gate via `:gate_preflight_fn` BEFORE `run_roles`, before any role is invoked or paid for. Resolution-only. An unresolvable gate raises at turn 0 with an actionable hint instead of crashing mid-cycle. Real gate still resolves+executes later in `do_gate_loop`.
- **Turn-0 role-agent resolution preflight** (`preflight_roles!/3`) — confirms every role resolves as an installed `--agent` BEFORE any role is invoked, via `:preflight_probe_fn` (default: sentinel probe, zero model turns). `missing = roles -- available` non-empty → raises naming missing roles + `make install` hint. No parseable line → raises (fail-closed). Tests: `orchestration_loop_test.exs`.
- **Warm-resume on transient retry** (`do_invoke_attempt/6`, `invoke_role/4`, `resume_prompt/1`) — transient failure resumes the SAME session (mint via `mint_session_id/0`, short continuation prompt). `stale_session_reason?/1` falls back cold. `CODEGEN_RESUME_ATTEMPT=<sid>` treats new token as fresh-run not spin.
- **Cycle-level resume** (`resume_checkpoint/3`) — turn-0 check for durable checkpoint (state ∈ {GATED, REVIEWED, CURATED} + gate clear + tree match + publishable changes + HEAD unmoved). Valid → resume at mapped role, skipping expensive prefix; clean/stale/invalid → `:full`. Seams: `:cycle_state_get_fn`, `:read_verdict_fn`, `:gate_tree_match_fn`, `:resume_work_present_fn`, `:gate_result_base_sha_fn`, `:log_resume_fn`. Recovery-dossier resume (distinct, `context/loop.md`): `park_failure/1`/`materialize/2`/`:recovery_mode`. Tests: `interrupted_cycle_recovery_test.exs`, `codegen_loop_test.exs`.
- **Single-pitch move** — `Mix.Tasks.Codegen.Loop.run/1` ships in BOTH modes (`--queue` spawns a solo child). `maybe_ship_pitch/4` moves `ready/<slug>.md` → `shipped/<slug>.md`, calling `LoopQueue.record_ship/4` first — stamps `shipped_sha:`/`shipped_range:` frontmatter BEFORE the mv (a died-before-mv failure never strands a shipped stamp on a pitch still in `ready/`). No second medium — the frontmatter stamp is the sole ship record. Fails open on non-git/nil sha. `LoopQueueDrain.ship/3` is the FALLBACK. Tests: `codegen_loop_test.exs`, `loop_queue_test.exs`.
- **Curator-stage pre-scan** — pre-invoke seed + post-turn backstop, see `context/loop.md` § Curator-Doc Check. Tests: `orchestration_loop_test.exs` describe "curator doc check cycle".
- **Pre-spend handoff check** — `claim_pitch!/2` verifies `handoff_receipt:` before the `ready/ -> building/` rename; invalid refuses `exit({:shutdown, 2})`, pitch stays in `ready/`.
- `LoopQueue` mirrors `retryable_regex` transient and Kahn topo-sort. `LoopQueueDrain.drain/1` is the sole `--queue` drainer: `claude-build.sh`/`pi-build.sh --queue` always runs `mix codegen.loop.queue` (via shared `loop-signal-bridge.sh`, non-exec). Shares `codegen/gate-pending/` lock with single-pitch builds. Operator output: per-pitch banner, two-path echo (`_cycle.jsonl`+`_build.log`, fail-open), streamed stderr, terminal outcomes; `_build.log` gzipped at 14d, deleted at 30d. Tests: `loop_queue_drain_test.exs`. Per-pitch child: `default_spawn_fn/5` invokes `codegen-build --harness=<h> --stack=<s> --cwd=<c> -- <pitch>`.
- **Committed-but-nonzero recovery** — `handle_nonzero_exit/7` detects committer-post-commit hiccup (HEAD moved + gate `"clear"` + fresh), counts pitch shipped instead of erroring. `committed?` forward-only (`head_before` must be an ancestor of new HEAD, via `:git_ancestor_fn`); non-descendant move halts loud with `git rebase --onto` remediation, pitch left `ready/`. Tests: `loop_queue_drain_test.exs` (`6r1`-`6r6`, `6r-orphan`, `6r-forward`, `6r-fresh-*`).
  - **Idempotency contract**: `LoopQueueDrain.ship/3` MUST be idempotent (`:ok` if dst exists) — the solo child usually ships first via `maybe_ship_pitch/4`; drain never fights it for ownership.
- **Gate-record freshness** — `LoopGate` writes `base_sha` = short HEAD at gate time (`""` if non-git); gate runs BEFORE committer, so sha only ever prefixes `head_before`, never post-commit `head_after`. `gate_fresh?/3` also requires gate mtime `>=` spawn `ts`, rejecting a stale verdict from an earlier non-committing cycle sharing the same base. Tests: `loop_gate_test.exs`.
- **Gate content binding** — `base_sha` pins HEAD only, not content. `LoopGate` also stamps `graded_tree_sha` (git tree object, temp-index refreshed; else `HEAD^{tree}`). `ensure_gate_graded_this_tree!/5` re-compares stamped vs. current tree before commit; mismatch re-gates (bounded `:max_final_gate_cycles`, default 1). `assert_commit_matches_gate!/1` re-checks post-commit. `""` either side → skip. Tests: `loop_gate_test.exs`/`orchestration_loop_test.exs`.
- **Turn-0 orientation-doc preflight** (`run_orientation_preflight/4`) — after `preflight_roles!/3`. `{:violations, v}` CLASSIFIED (`classify_orientation_violations/1`): all-curator-writable → lazy `context-curator` + shared `run_orientation_repair/1` (never advances `CURATED`); else → `InfraAbort` (exit 3, `ready/`), never partial; exhaustion → owned `{:error, _}`. Tests: describe "run/1 — turn-0 orientation-doc preflight".
- **Repair loops (`repair_allowed?/4`), floor-then-progress**: `:max_curator_doc_cycles`/`:max_env_var_cycles` are a floor; beyond it, rework only if a prior violation resolved, capped by `@repair_progress_ceiling` (15). Backs `run_orientation_repair/1` too. Tests: `orchestration_loop_test.exs`.
- **Deterministic failure handling**, **Publish-on-ship** (`:publish_preflight_fn`, `publish_or_halt/4` → `:git_publish_fn`: ff/push, rebase+push, or conflict → recovery branch + HALT, never `--force`) — full contracts → `context/loop-queue-drain.md`. Tests: `loop_queue_drain_test.exs`.
- State advancement (GATED→REVIEWED→CURATED→COMMITTED) shells `cycle-state.sh` via `advance_cycle_state_step/3`.
- **`--watch`** (`--queue --watch`): empty `ready/` sleeps (`CODEGEN_BUILD_QUEUE_POLL_SECS`, default 60) + re-scans instead of returning; other exits unchanged. Quiescence gate (`CODEGEN_BUILD_QUEUE_QUIESCE_SECS`, default 30, via `:mtime_fn`) excludes a mid-`scp` pitch from `ordered_fn`/`blocked_fn` BEFORE they run (`LoopQueue.*` `exclude` param). Darwin: `:keychain_fn` pre-spawn check (fail-closed) + `caffeinate -dimsu` guard the Keychain-sleep failure. Tests: `loop_queue_drain_test.exs` "`:watch`" describes.
- **Pitch-path resolution contract** — `dispatch.sh` runs `cd "$LOOP_DIR"` (`$LOOP_DIR` = `<repo>/test_harness/`) before execing `mix codegen.loop`. Any mix task resolving a relative file path (pitch arg, draft slug) MUST join it against the explicit `--cwd` flag (the real project root), never `File.cwd!()`. Pattern: `Path.expand(relative_path, cwd)`. Applies to any future mix task accepting a file-path arg.
- **`build_prompt/2` testability & reviewer file set** — Prompt-assembly point in `OrchestrationLoop.build_prompt(role, ctx)`. `def`+`@doc false` for direct ExUnit calls. Reviewer branch renders loop-derived `## Files Modified` list (`invoke_reviewer/4` → `default_review_file_set_fn/1`, mirrors `default_rework_brief_fn/1`'s git idiom); content via `git diff HEAD -- <path>`. Empty set in real git tree → loop refuses reviewer invoke. Gate-clear drops `:last_failure_reason` — no stale leak into reviewer prompt.

## Make Target Catalog

| Target                       | Purpose                                                                                                                     |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `make test-stacks`           | Runs full ExUnit suite across all stacks (`mix test --only slow`; real LLM)                                                 |
| `make test-stacks-claude`    | Runs ExUnit suite for Claude harness only (`mix test --only slow`)                                                          |
| `make test-stacks-pi`        | Runs ExUnit suite for Pi harness only (`mix test --only slow`)                                                              |
| `make test-hermetic`         | Deterministic ExUnit (`--exclude slow --max-cases ${EXUNIT_MAX_CASES:-24}`); no LLM                                          |
| `make test`                  | Core-gated: high-core overlaps hooks/hermetic/render in phase 1; low-core keeps serial tail; no LLM                          |
| `make record-green`          | Stamps `last_green.json` with current commit SHA after clean `test-stacks`                                                  |
| `make test-harness-parity`   | Runs cross-harness parity suite (`--only harness_parity`, distinct `_build/parity_test`); runs once as `test-stacks` prereq |
| `make check-green-staleness` | Diagnostic: exits 1 if `last_green.json` is >7 days old; standalone, not a `test`/`test-stacks` prereq                      |

## Gate Invariant: `--only slow` / `--exclude slow` & Hermetic Assertions

The ExUnit suite uses `@moduletag :slow` to partition LLM-driven tests from deterministic fast tests:

- `make test-stacks-claude` / `make test-stacks-pi` → `mix test --only slow` — only runs LLM-dependent tests tagged `:slow`
- `make test-hermetic` → `mix test --exclude slow` — only runs fast, deterministic tests

**Critical**: tests added to the gate suite (e.g., `ops_test.exs`, `headless_launcher_test.exs`) MUST have `@moduletag :slow` to be included in `make test-stacks`. Omitting the `:slow` tag silently excludes them from the LLM gate via `test_helper.exs: exclude: [:slow]` — they will run under `test-hermetic` instead, defeating gate coverage.

**Deterministic vs. slow test placement**: A new test that does NOT call the actual agent binary (stubs via `System.cmd` with mocked binaries) MUST NOT carry `@moduletag :slow` — it runs under `make test` hermetic ExUnit. Example: `build_test.exs` stubs `codegen-build` from a nested `codegen/pitches/` cwd, verifying launcher path normalization; deterministic assertions (exit 0, arg capture, mention prefix) need no `:slow` tag — runs at `make test` time, not `make test-stacks`, avoiding cold-compile cost per full-suite run while still testing the contract.

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

### Install Arm — Concurrency + Isolation

`test_harness/install/run-tests.sh` backgrounds each `*_test.sh`, per-file output, prints only on failure — hermetic (own `tmp_home`), safe in parallel (~72s serial/cold → ~13-26s). Round-trip tests export before `HOME` swap: `PLAYWRIGHT_BROWSERS_PATH` (real cache, avoids re-download; unset falls through), `OCG_GENERATED_DIR` (unique per test, prevents `rm -rf` collision), and `OCG_RENDERED_APPS_DIR` (same convention — isolates rendered `shared/apps/*.md`; missing `.j2` source now raises loudly, not warn-skip). Shared symlink loop un-isolated — race-tolerant (`ln -sfn ... || true`).

## Integration Points

- **scaffold**: tests exercise `shared/scaffold/<stack>/scaffold.sh` output — scaffold changes require test updates; see `context/scaffold.md`
- **core**: `generate.sh` output (rendered agent files) may be asserted against in tests
- **development**: `make test-stacks` runs the ExUnit suite; `make record-green` stamps last_green after CI passes; see `context/development.md` for full make-target index
- **hooks**: hook bash tests (`*_test.sh`) are separate — run via `harnesses/claude/hooks/run-tests.sh`, not `mix test`; see `context/hooks.md`

Seam threading (preserving test-override capacity when adding new fn params) + RoleResolver shape-change ripple to sibling tests → `context/test-harness-pitfalls.md`. Fixture/flake/Ecto/Port gotchas that overflow this file also live there.

## Testing Patterns

### Hermetic Bash Test Assertion Pattern

Hermetic bash tests (e.g., `*_test.sh` hook tests) should assert on **committed, in-repo source files** rather than machine-dependent install artifacts (e.g., `~/.claude/`) — paths vary by machine/role, CI may lack `~/.claude/` entirely. `~/.claude/commands/ready.md` is non-hermetic; source `harnesses/claude/commands/ready.md.j2` is hermetic. For generated artifacts (baked system prompts), assert on the **committed** baked files (e.g. `harnesses/claude/claude-shape-system-prompt.txt`) — generated at `make install`, checked in.

### Render-Check Test Pattern

New bash test files under `harnesses/claude/hooks/` are auto-discovered by `run-tests.sh` via `find *_test.sh` — no registration needed (unless ALSO a direct Makefile caller — then add to `HOOK_DEDUP_EXCLUDE` in `run-all-tests.sh` for one-owner execution under `make test`, guarded by `run-all-tests_test.sh`). When testing crash paths (e.g., render-check.js parse failures), use `make_render_stub` for normal cases, skip it for crash-path stubs: write garbage via `cat > stub <<'STUB' ... STUB` with no `RENDER_VERDICT=`. Regression guard: `node --check` in `render-check_test.sh` catches dup fn defs/parse errors early (cf. session 20260608_153448).

### Stub-Binary Test Pattern for Launchers

When testing launcher logic (e.g., cwd normalization in build launchers `claude-build.sh` / `pi-build.sh`), stub the underlying binary the launcher execs (`BUILD_BIN`=codegen-build, resolved via `OCG_CODEGEN_DIR`/`SCRIPT_DIR`, cwd-independent) — NOT the agent binary. Stub: temp dir, binary named `codegen-build`, `OCG_CODEGEN_DIR=stub_dir`; captures invocation args, exits 0. Assertions verify correct args (e.g. harness-appropriate pitch mention: `@codegen/pitches/ready/<slug>.md` claude vs `codegen/pitches/ready/<slug>.md` pi) before exec. Isolates launcher path logic, hermetic, no `@moduletag :slow`.

### Module-Attribute Data Loading via Code.eval_file

Data files can be loaded at **compile-time** (not test invocation) via `Code.eval_file/1` at module-attribute scope. Example: parity allowlist in `known_divergent.exs` ships as an empty Elixir list `[]`; loaded via `@allowlist Code.eval_file(Path.join(__DIR__, "known_divergent.exs")) |> elem(0)`. Evaluation happens once at module compilation, the result is bound to a compile-time constant `@allowlist`, and zero runtime I/O occurs on every test invocation. This pattern is appropriate for small, stable data files (e.g., divergence reasons, skip lists) that live alongside test modules.

### Bash Test Numbering Conventions

Hermetic bash test files (e.g., `prompt-content-parity_test.sh`) using sequential `# Test N` comment labels should renumber ALL labels when a new test is inserted mid-file, to avoid duplicates. Bookkeeping cost accepted — labels are documentation, not code-critical.

### Fixture Invalidation on Hook Logic Changes

Widening a hook's conditional (e.g., exact-match → `startsWith`) can make fixtures relying on the old fallthrough to `else` INVALID — must be converted, not kept as-is. **Critical**: grep paired test file(s) for fixtures the change may invalidate; convert before landing.

### Test Mock Anti-Pattern: Encoding the Prod Bug

A fixture can encode the SAME false premise as the prod bug it should catch (suite stays green through regressions). Fix: re-model the fixture correctly + add producer/consumer reconciliation tests running the REAL producer against the REAL consumer's predicate.

### Fixture and Build Patterns

- Tests scaffold a temp app, assert generated file contents, run `mix compile` or `npm run build` on output
- `last_green.json` is checked in — diff against it to spot regressions before merging
- Run a single test file: `mix test test/stacks/phoenix_test.exs` from `test_harness/`
- Async: most stack tests are synchronous (file system I/O)
- **ExUnit concurrency**: `max_cases` governs parallel test modules; tests within one module remain serial. `make test-hermetic` sets `${EXUNIT_MAX_CASES:-24}` because subprocess-heavy cases benefit beyond scheduler count. Split fat modules into `defmodule` siblings. Slow stack targets retain natural ExUnit scheduling.

## Deterministic Scaffold Testing vs. LLM-Driven Build Testing

**Two distinct test paths**:

1. **Deterministic scaffold variants** (e.g., `--no-ecto`): Use direct `codegen-scaffold` invocation via fixture helpers; no LLM involved. Validates scaffold output structure and compile correctness. Examples: `no_ecto_scaffold_test.exs` uses `run_no_ecto_scaffold/2`.
2. **LLM-driven builds**: Use `run_codegen_build/3` (harness launcher via JSONL stream). Validates LLM iteration patterns, commit messages, reviewer phase. Example: `scaffold_test.exs` via `run_codegen_build`.

**Timeouts**: Deterministic scaffold (fixture setup only) seconds. Multi-phase LLM builds (scaffold + dev + review + commit) 210+ sec/iteration (deps.get 60s + compile 90s + LLM roundtrip 30-60s). **Fixture flags**: `run_codegen_call/3` pre-wires `--model`/`--effort` by resolving from `config.yaml` via `config_yaml_read!`, never as empty defaults; always Read helpers to confirm what flags are baked before proposing additions.

## Fixture Isolation + Build Paths

`Fixtures.isolated_tmp_dir/1` creates separate temp directories for each harness test, with stack-specific config:

- `isolated_tmp_dir(stack: :phoenix)` creates via `codegen-scaffold create`; the generated app is its own clean committed repo even when the temp parent lies under this repo.
- Non-Phoenix fixtures initialize and commit their own repo.
- `prepare_codegen_build_baseline!/2` runs deterministic `codegen-scaffold integrate` and commits it before normal and parity `codegen-build` helpers enter the loop. The loop's clean-tree preflight therefore still rejects later source dirt without mistaking scaffold integration for foreign work.

**Gate verdict parity**: Both phoenix and static stacks write the ephemeral gate-result JSON into `codegen/gate-pending/` via the `write_gate_result` shell fn (`gate-result.sh`), called from `LoopGate.run_gate/2` — the sole build engine (no separate interactive-session fallback path or caller exists). Test assertions mirroring the gate-result JSON schema are valid across stacks.

**Build path isolation**: Tests using `mix` with non-default `MIX_BUILD_PATH=_build/pi_test` (pi tests) require recompilation of fixture-modified files under BOTH the default and custom build paths. A stale `_build/pi_test` still serves old BEAM bytecode after fixture changes until that tree is recompiled. Solution: run `mix compile` after fixture code edits without the env var, then again with the env var set.

**Arity + BEAM**: Default-arg functions export both arity-0 and arity-1 in BEAM; stale `.beam` under non-default `MIX_BUILD_PATH` silently serves old signatures until recompilation. **Environment isolation**: `env: []` clears entire process environment; safe only for git. Mix commands need `env: :inherit` or omit `:env`. **Parallel isolation**: concurrent suites need distinct `MIX_BUILD_PATH` to avoid BEAM clobbering (`_build/parity_test` vs `_build/claude_test` / `_build/pi_test`).

Benchmark mode (BENCH=1), artifact layout, screenshot capture, mix viewer tasks: → see `context/test-benchmarking.md`.

## Pitfalls

- **Fixture prompt suffixes must not contradict assigned role** — appending `@commit_contract_suffix` or similar fixture-embedded "commit directly via bash" instructions conflicts with the loop's dedicated committer role. If obeyed → `loop_failed` on 2+ commits; if ignored → reviewer correctly reds for contradicting discipline. The loop's `assert_work_produced!` is the strongest guard. Always audit build prompts for role conflicts.
- **Leaf test summary format is load-bearing** — `N passed, N failed` or `Results: N passed, N failed`. Preserve exact format per leaf; grep patterns require exact match.
- **Round-trip tests fail loud on missing tools** — require claude, jq, yq, rg, node on PATH; fail explicitly if absent.
- **`mix test` must be scoped** — bare `mix test` runs all tests; use file/tag filter (`--only phoenix`).
- **`last_green.json` is not auto-updated** — run `make record-green` explicitly after clean suite.
- **Hook tests are bash** — do not run via `mix test`; use `run-tests.sh`.
- **Gate-failure-path tests are `:slow`** — verdict != "clear" tests require real hooks; tag `:slow`, run only `make test-stacks`.
- **`mix assets.deploy` silent no-op risk** — guard assertions with filesystem checks (assets/ dir + alias in mix.exs).
- **`phx_new` 1.8.7+ no `--force`** — use `mix phx.new . --app <name> --live`.
- **`run_with_timeout/4` return order** — `{output, exit_code}` (output-first).
- **`assert_assets_deploy!` needs `MIX_ENV=dev`** — tailwind is dev-only.
- **`codegen-call` requires `--model`, `--effort`, `@<abs-path>`** — resolve from config.yaml, write temps.
- **Private helpers per-module only** — promote to public module to share.
- **`default_spawn_fn/5` timeout kills child tree** — use `Port.open` loop, not `Task.shutdown`.
- **`bench_artifacts_test.exs`** — update token list on screenshot.js changes.
- **Post-review curator prompt coverage** — `orchestration_loop_test.exs` asserts the curator stage contract, unchanged developer self-gate, preserved turn-0 orientation repair block, and `REVIEWED` checkpoint resume behavior.

## Trigger Keywords

test_harness, test-stacks, last_green, record-green.sh, stack scaffold test, ExUnit assertions, role resolver, orchestration loop, mix codegen.loop, mix codegen.loop.queue, mix codegen.pitches.scope, LoopGate, LoopQueue, LoopQueueDrain, claude-build --queue, pi-build --queue, flake triage, hermetic regression guards, scope: frontmatter, post-review curator gate ownership
