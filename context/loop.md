# The Elixir Orchestration Loop — Build Engine

The deterministic cycle driver that runs every codegen build. `dispatch.sh` (both harnesses) always
execs `mix codegen.loop --harness=<h> --stack=<s> --cwd=<cwd>` — there is no legacy self-orchestrating
harness session, no engine flag, no alternative path. Previously this sequencing logic was encoded
across ~25 hand-authored hooks + an orchestrator role prompt; it is now plain Elixir control flow that
crashes loud on unexpected state.

**Owner of this domain** — was previously routed to `context/hooks.md` (wrong; that file's own text
disclaims the loop and forwards elsewhere) and `context/test-harness.md` (wrong domain — that file
owns the ExUnit stack SUITE, not the engine under test).

## Module Map (7,900 LOC total across the engine family)

| Module                                                              | LOC   | Owns                                                                               |
| ------------------------------------------------------------------- | ----- | ---------------------------------------------------------------------------------- |
| `CodegenTestHarness.OrchestrationLoop` (`orchestration_loop.ex`)    | 3,346 | the cycle driver — `run/1`, role sequencing, retry, resume, budget cap, escalation |
| `CodegenTestHarness.LoopGate` (`loop_gate.ex`)                      | 1,068 | gate execution + verdict classification (deterministic)                            |
| `CodegenTestHarness.LoopQueue` (`loop_queue.ex`)                    | 902   | single-pitch queue state machine                                                   |
| `CodegenTestHarness.BuildLock` (`build_lock.ex`)                    | 187   | solo-run mutex, PID-liveness check                                                 |
| `CodegenTestHarness.BuildSignalHandler` (`build_signal_handler.ex`) | 160   | SIGINT/SIGTERM → halt 130                                                          |
| `CodegenTestHarness.LoopQueueDrain` (`loop_queue_drain.ex`)         | 2,237 | multi-pitch drain — separate domain, own owner file                                |

## The Decider Map — What Is LLM vs Deterministic (swept, exactly 4 LLM stages of 42)

| Stage                                                             | Decider                                                                                                                                                                                                                                                     | Where                                                                                                                                         |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| dev-gate execution                                                | **LLM** (loop only renders prompt text)                                                                                                                                                                                                                     | dev-role invocation                                                                                                                           |
| review verdict                                                    | **LLM**-authored, deterministically PARSED — unparseable → `:unknown` → **proceeds** (fail-open on parse, not on the verdict itself)                                                                                                                        | reviewer body parse                                                                                                                           |
| the commit                                                        | **LLM** (committer subagent runs `git commit`)                                                                                                                                                                                                              | committer invocation                                                                                                                          |
| `COMMITTED: <sha>` line                                           | **LLM**-authored — **no Elixir producer, parser, or consumer exists** for this exact string; do not build logic that expects to find it                                                                                                                     | committer.md convention only                                                                                                                  |
| gate verdict clear/failed                                         | **deterministic**; `"inconclusive"` fails closed to `:failed`                                                                                                                                                                                               | `LoopGate` — see the cycle-record owner file's Gate Verdict Truth Table                                                                       |
| infra-vs-code classification                                      | **deterministic** — 6 regex signatures, default is always `:code` (never excuses a failure as infra unless matched)                                                                                                                                         | `LoopGate.classify_failure/1`                                                                                                                 |
| gate-failure OWNER routing (`:code` → which role)                 | **deterministic** — a context-doc-shaped witness (`context/*.md`/`PROJECT_CONTEXT.md`) routes to `context-curator`; everything else routes to the cycle's own developer (unchanged default)                                                                 | `OrchestrationLoop.default_gate_classify_fn/2` + `resolve_gate_owner/2`, reading `LoopGate.failing_check/1`                                   |
| gate-failure load-flake absorption                                | **deterministic** — one standalone re-run of the SAME gate command before any rework attempt is consumed; green → re-run full gate once (attempt not spent), red → real routing                                                                             | `OrchestrationLoop.do_gate_loop_flake_check/10`                                                                                               |
| stale-`_build` gate self-heal                                     | **deterministic** — signature (≥2 distinct "module ... is not available") + count threshold; nukes `_build` roots, re-runs the FULL gate once (attempt not spent); still stale → falls through to ordinary owner rework, never re-heals the same occurrence | `LoopGate.stale_build?/1` + `OrchestrationLoop.do_gate_loop_stale_build_heal/10`                                                              |
| claim `ready/`→`building/` (possession)                           | **deterministic** — atomic `File.rename/2`; a race loser gets ENOENT and refuses (exit 2)                                                                                                                                                                   | `Mix.Tasks.Codegen.Loop.claim_pitch!/2`, called before `OrchestrationLoop.run/1`                                                              |
| ship `ready/`\|`building/`→`shipped/`                             | **deterministic** — retire is UNCONDITIONAL on a verified landing (`record_ship` + `File.rename!` run FIRST); a dirty tree fires a LOUD non-fatal-to-the-ship exit (`4`), never a raise that strands the pitch                                              | `Mix.Tasks.Codegen.Loop.ship_ready_pitch/6` + `warn_dirty_after_retire/1` (NOT `OrchestrationLoop.run/1` — a documented prior misattribution) |
| commit verification                                               | **deterministic** — clean tree, exactly-one-commit, commit tree hash == graded tree hash                                                                                                                                                                    | `OrchestrationLoop` post-committer check                                                                                                      |
| budget cap, watchdog, lock, retries, fallback, signals, telemetry | **deterministic**                                                                                                                                                                                                                                           | see below                                                                                                                                     |

Every other stage in the 42-stage cycle is deterministic Elixir control flow. Treat "is this an LLM
decision or a deterministic one" as answerable per-stage from this table — do not assume.

## Possession by Rename — `building/`

A pitch whose work has landed on develop must never be handed to a builder again — see
`codegen/pitches/shipped/a-landed-pitch-cannot-be-handed-out-again.md`. Two mechanisms close this,
both in `Mix.Tasks.Codegen.Loop`:

1. **Claim at cycle start.** `claim_pitch!/2` atomically renames a `ready/<slug>.md` source to
   `building/<slug>.md` BEFORE `OrchestrationLoop.run/1` runs. `File.rename/2` on one filesystem is
   atomic — a second builder racing on the same slug gets `{:error, :enoent}` (the source is already
   gone) and refuses loud: `exit({:shutdown, 2})` naming the slug as "already claimed (building/)".
   A pitch is therefore physically in `ready/` only while UNSELECTED (unmet dep, not yet reached) or
   after a diff-failure restore — a pitch mid-cycle lives in `building/`.
2. **Retire follows git truth, unconditionally.** `ship_ready_pitch/6` runs `LoopQueue.record_ship/4`
   - `File.rename!` to `shipped/` FIRST, on any VERIFIED landing (`verify_commit_landed/2` already
     proved HEAD advanced + ancestor-extended) — regardless of whether the working tree is clean. THEN
     `warn_dirty_after_retire/1` checks `git status --porcelain`; a dirty tree fires a LOUD, distinct
     exit code (`@dirty_tree_exit_code`, `4`) naming the dirty files, but the pitch has ALREADY left
     `ready/`/`building/` — the exit can no longer strand it back in a dispatchable directory.

**Restore on diff-failure only.** `restore_claim/2` moves a claimed pitch back from `building/` to
`ready/` on the two diff-failure exit arms (`verify_commit_landed` error, `OrchestrationLoop.run`
error) — the pitch's work did NOT land, so it must remain dispatchable. `restore_claim/2` is
DELIBERATELY NOT called from `run_loop_catching_infra_abort/1`'s `InfraAbort` rescue — an infra
abort leaves the pitch in `building/`, mirroring `LoopQueueDrain.handle_infra_abort/4`'s existing
"pitch remains untouched" posture (the box is broken; nothing about the pitch was wrong). A crashed
build strands its slug in `building/` indefinitely — deliberately never auto-reconciled; `codegen-drain
status` surfaces the count, the operator decides.

`LoopQueue.write_frontmatter!/4` (the ship-time stamp) and `LoopQueueDrain.ship/6` (the drain's own
non-compliance fallback ship) both probe `building/` alongside `ready/`/`shipped/` — required, not
cosmetic: without the probe, every claimed pitch's ship-time stamp or fallback ship raises.
`LoopQueue.ordered_slugs/2` and `blocked_by_unmet_dep/3` deliberately keep reading `ready/` only — a
claimed (`building/`) pitch is invisible to selection, and a dependent whose dep is in-flight
correctly stays blocked (in-flight ≠ shipped).

## Per-Cycle Spend Cap

`--max-budget-usd` (CLI) → `opts[:max_budget_usd]` → `OrchestrationLoop` private `check_budget/1`.
Checked AFTER a role's cost is accumulated into telemetry (already billed — killing mid-call saves
nothing) and BEFORE the next role is invoked. `nil` (absent, default) → always `:ok`, unchanged
behavior. Present + `telemetry.cost_usd >= cap` → `{:error, "spend cap reached: ..."}`, cycle aborts
before next role. This is the PER-CYCLE cap — distinct from the queue drain's queue-wide
`CODEGEN_BUILD_QUEUE_BUDGET_USD` (see the loop-queue-drain owner file).

## Envelope Classifier — Planner-Plan-Present Override

`invoke_role/4`'s `case envelope do` classifier normally maps `status:"failed"` straight to
`{:error, reason}`. One override sits before that: a PLANNER role (`planner_role?/1`) whose cycle log
already carries a valid, non-blank typed `{"ev":"plan",...}` event (read via the SAME
`:planner_plan_fn` seam `resolve_planner_plan!/2` uses one step later, default
`LoopGate.planner_plan/1`) is promoted to `{:ok, result}` even though the envelope said `"failed"`.
Rationale: `role-retrospective-before-stop` forces every role, including the planner, to end its final
turn on a mandated `codegen-log --learned` tool call — sometimes with no trailing assistant text, which
call-dispatch classifies as `status:"failed"`. The planner's real deliverable (the plan) is a durable
typed event, not the chat turn, so a tool-final turn must not fail a cycle that already has a valid
plan. A plan-less planner (blank/absent `{"ev":"plan"}`) still fails loud — the override is gated on
BOTH `planner_role?(role)` AND a non-empty plan string; no other role is affected.

## Model Escalation Ladder

`maybe_escalate_model/5` fires ONLY on the FINAL gate-retry attempt (not every retry) for a dev role,
via `RoleResolver.resolve_escalation/2` (test-seam override: `opts[:resolve_escalation_fn]`). Returns
`{model, effort}` to escalate to, or `:none`. On escalation, logs an operator note and stashes
`{model, effort}` at `ctx.artifacts.escalated_model` for the retry's `codegen-call` invocation. See the
role-config owner file for the ladder's actual rung values.

## Build Lock

`BuildLock.acquire(lock_path, "solo", pid_alive_fn)` — mutex preventing two concurrent solo builds in
the same cwd. `pid_alive_fn` defaults to `BuildLock.default_pid_alive?/1` (`kill -0` liveness check) —
a stale lock from a dead PID is reclaimed, not blocked on forever. Released via `BuildLock.release/1` on
both success and failure paths (loop uses `try/after` semantics around the guarded body).

**`<label>` is a read contract, not diagnostics-only.** `LoopQueueDrain` writes exactly `"queue"`;
`OrchestrationLoop` writes exactly `"solo"`. `codegen-drain status` (`context/deployment-topology.md`)
reads this literal to resolve its `watcher=` column — `"queue"` + a live pid means the fleet node is
under queue supervision, `"solo"` means one pitch is building unsupervised. Changing either literal, or
the lock line's field order, silently breaks that consumer (fails closed to `watcher=no`, never a
crash) — guarded by `test_harness/test/codegen_test_harness/build_lock_test.exs` and registered in
`shared/enforcement/seam-registry.yaml` (`build-lock-format-to-codegen-drain-status`).

## Signal Handling

`BuildSignalHandler` traps SIGINT/SIGTERM during a run and halts with exit code 130 (standard
128+SIGINT convention) rather than letting a partial cycle exit 0 or silently swallow the signal.

## Warm-Resume

`resume_checkpoint/3` inspects `codegen/gate-pending/cycle-state.json` for a durable checkpoint
(`GATED`/`REVIEWED`/`CURATED` states map to resuming at `reviewer`/`context-curator`/`committer`
respectively via `resume_role_for_state/1`). A resume is honored ONLY when ALL of: the mapped resume
role is present in `roles` for this stack, **the checkpoint's stamped `slug` matches this cycle's
`opts[:slug]` (identity guard — prevents pitch A's orphaned checkpoint from being resumed by pitch B)**,
the gate verdict at checkpoint time reads as non-error (missing verdict is NOT silently treated as clear —
an explicit check), and `resume_head_unmoved?/2` confirms HEAD hasn't moved since the checkpoint (stale
checkpoint after an external commit → full run, never a corrupt resume). Resume replaces the full
pitch/plan prompt with a continuation prompt (the resumed session already carries prior tool-call history
in its transcript). An empty or foreign slug → full run, never resume.

## Curator-Doc Check (Three Legs)

After the context-curator role, `run_curator_doc_check/6` shells `default_curator_doc_scan/2`
(dispatched via the `:curator_doc_check_fn` seam, still arity-1 for the 30+ existing test overrides —
the default closure captures `gate_opts(opts)` itself, since this step runs upstream of
`run_gate_once/2`'s own `gate_opts/1` call and has to resolve `:cycle_log` on its own). Three checks,
joined into one violations message via `combine_curator_doc_results/2` folded twice:

1. **Index-parity** (`context-index-parity-scan.sh <cwd>`) — cross-file `context/*.md` add/delete vs
   `PROJECT_CONTEXT.md` § Domain Context Files parity.
2. **Factcheck backstop** (`context-factcheck-scan.sh <cwd> <doc>...`) — diff-scoped to this cycle's own
   `changed_orientation_docs/1`; catches a Bash write the PreToolUse edit-gate hook never saw.
3. **Consumption check** (`curator-consumption-scan.sh <cwd> <cycle_log>`) — asserts that when this
   cycle captured upstream `{"ev":"learned"}` events (planner/developer/reviewer), the curator either
   routed at least one into a durable doc (working-tree diff or untracked file matching
   `^(context/[^/]+\.md|shared/rules/.*\.md)$`) or recorded each drop as its own `{"ev":"learned"}`
   event. **Path-filter trap**: curator edits are conventionally spelled `codegen/rules/**` in docs/rules,
   but `codegen/rules` is a symlink into `shared/rules/` and `/codegen/` is gitignored — `git` NEVER
   reports a path spelled `codegen/rules/**` (`git check-ignore` on that spelling errors "pathspec is
   beyond a symbolic link"). Any path filter consumed against `git diff`/`ls-files` output MUST use the
   `shared/rules/**` spelling or it matches nothing, ever, and passes vacuously. `opts[:cycle_log]` is
   `nil` for most unit tests (no `:slug` → `Process.put(@log_path_key, ...)` never runs in `run/1`) —
   `nil` skips this leg with `{:clean}`, not an error; a present-but-unreadable log path is fail-closed
   (exit 1, cannot prove consumption). See pitch `no-role-work-recorded-without-its-learning`.

Violations from any leg that are NOT classified `:infra` (`LoopGate.classify_failure/1`) route into the
progress-bounded rework loop (`:max_curator_doc_cycles`, floor 1, ceiling 15 via `repair_allowed?/4`);
`:infra`-classified violations raise `LoopGate.infra_abort!/2` immediately (unsatisfiable by any curator
edit). Budget exhaustion fails the cycle LOUD (`curator_doc_check_exhausted/3`) — the committer cannot
Read/Edit `context/*.md`, so handing it a known-bad doc is an unfixable dead-end.

## Infra Abort

`LoopGate.infra_abort!/2` raises `CodegenTestHarness.InfraAbort` — reserved for genuine infrastructure
failures (not code/test failures), which the loop routes distinctly from a normal gate `:failed`
verdict. See the cycle-record owner file's infra-vs-code classification section for the signature list.

## Timing/Metrics Telemetry (consume, don't produce)

`OrchestrationLoop.accumulate_telemetry/2` and the private `write_cycle_summary/6` both widen their read
of the per-role envelope's `usage`/`metrics` fields rather than adding a new clock — both harnesses'
`call-dispatch.sh` already compute `latency_ms` and (Claude only, success path) lift `duration_ms` /
`duration_api_ms` / `ttft_ms` / `permission_denials` / `stop_reason` from the underlying `result` event
(see `context/call-contract.md`). **Unknown stays unknown**: a dedicated `t_opt_int/1` helper (sibling
of the pre-existing `t_int/1`, which backs arithmetic sums and stays byte-identical) carries an
absent/malformed value through as `nil` rather than coercing it to a fabricated `0` — a `cycle-summary.jsonl`
row with `"duration_ms": null` means unknown, never "instant". `metrics` is entirely OMITTED (not
zeroed) by the envelope on any abnormal call; the loop reads it as `nil`-when-absent for the same
reason, never defaulting to `%{}`.

`LoopGate.run_gate/2`'s gate-verdict calls now carry an attributable `:session_id` — `gate_opts/2`
(private) resolves it from the developer role that just ran (either the caller's own already-known
`dev_role` parameter, or `dev_role_from_ctx/1` as a fallback) instead of the anonymous `""` default
`LoopGate.run_gate/2` itself still falls back to when no opt is supplied. `gate-result.sh`'s
`write_gate_result` derives `duration_s` from the same `started`/`ended` ISO8601 timestamps it already
receives (via `jq`'s `fromdateiso8601`, portable across macOS/Linux — never a bash `date -d`/`date -j`
diff), recording `null` when either timestamp is unparseable.

## Terminal Marker — Deterministic Exhaustion vs Recoverable Transient

`OrchestrationLoop.write_terminal_marker/3` writes `codegen/gate-pending/terminal-state.json`
(`{terminal: true, reason, owner}`) whenever a rework loop's OWNING role genuinely exhausts its
progress+ceiling bound — gate rework (`do_gate_loop_rework/9`), curator-doc check
(`curator_doc_check_exhausted/3`), or env-var check (`run_env_var_step_rework/9`) — immediately
alongside the `{:error, ...}` it already returns. This DOES NOT change the `{:error}`/exit-1 return
value; it is a durable, additional signal distinguishing a DETERMINISTIC exhaustion ("this cycle cannot
succeed however many times you run it") from a RECOVERABLE transient exit (a process death mid-cycle).

Deliberately NOT `InfraAbort`/exit 3: every marker-writing caller is PITCH-SPECIFIC (this cycle's own
gate/doc/env exhaustion) — the next pitch in a drain is unaffected, so the queue should skip and continue
rather than HALT. Exit 3 stays reserved for genuinely repo-wide infra faults (see Infra Abort above).

The marker is unlinked at the start of every FULL (non-resumed) cycle — see `run_body/1`'s `:full`
branch — so a stale marker from an earlier, already-concluded cycle never leaks into a fresh one.
`LoopQueueDrain` is the consumer: see the loop-queue-drain owner file's "Deterministic Failure — Skip"
section for how a marked nonzero exit routes to park+skip+breaker instead of `retry_eligible?/5`.

## Trigger Keywords

orchestration loop, OrchestrationLoop, mix codegen.loop, BuildLock, BuildSignalHandler, warm-resume, resume checkpoint, escalate_model, maybe_escalate_model, max-budget-usd, spend cap, per-cycle budget, decider map, infra abort, LoopGate, gate verdict, deterministic engine, LLM vs deterministic, curator doc check, curator consumption scan, index-parity, factcheck, learnings consumed, ev:learned routing, cycle-summary timing, duration_ms, latency_ms, t_opt_int, gate session_id, duration_s, telemetry, terminal marker, terminal-state.json, owner routing, gate failure owner, flake check, load flake
