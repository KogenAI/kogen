# The Elixir Orchestration Loop — Build Engine

The deterministic cycle driver that runs every codegen build. `dispatch.sh` (both harnesses) always
execs `mix codegen.loop --harness=<h> --stack=<s> --cwd=<cwd>` — there is no legacy self-orchestrating
harness session, no engine flag, no alternative path. Previously this sequencing logic was encoded
across ~25 hand-authored hooks + an orchestrator role prompt; it is now plain Elixir control flow that
crashes loud on unexpected state.

**Owner of this domain** — was previously routed to `context/hooks.md` (wrong; that file's own text
disclaims the loop and forwards elsewhere) and `context/test-harness.md` (wrong domain — that file
owns the ExUnit stack SUITE, not the engine under test).

## Module Map

| Module                                                              | Owns                                                                               |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `CodegenTestHarness.OrchestrationLoop` (`orchestration_loop.ex`)    | the cycle driver — `run/1`, role sequencing, retry, resume, budget cap, escalation |
| `CodegenTestHarness.LoopGate` (`loop_gate.ex`)                      | gate execution + verdict classification (deterministic)                            |
| `CodegenTestHarness.LoopQueue` (`loop_queue.ex`)                    | single-pitch queue state machine                                                   |
| `CodegenTestHarness.BuildLock` (`build_lock.ex`)                    | solo-run mutex, PID-liveness check                                                 |
| `CodegenTestHarness.BuildSignalHandler` (`build_signal_handler.ex`) | SIGINT/SIGTERM → halt 130                                                          |
| `CodegenTestHarness.LoopQueueDrain` (`loop_queue_drain.ex`)         | multi-pitch drain — separate domain, own owner file                                |

## LLM vs Deterministic — 2 of 42 Stages

| Stage                                                             | Decider                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Where                                                                                                                                                 |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| dev-gate execution                                                | **LLM** (loop only renders prompt text)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | dev-role invocation                                                                                                                                   |
| review verdict                                                    | **LLM**-authored, deterministically PARSED. PRIMARY channel: schema-validated typed decision — every `reviewer-*` call requests `review-verdict.schema.json` (`{"verdict","body"}`) via `invoke_role/4`'s `json_schema_path` (gated on `reviewer_role?/1`). Both reviewer agent templates grant `StructuredOutput` in `tools:` (required — an agent's frontmatter `tools:` list is the ONLY grant site for a role call; `--allowed-tools` is never passed and could not raise it if it were, since the frontmatter list is a floor, not a ceiling). `normalize_reviewer_result/3` rewrites a "success" envelope's `result["value"]` back to the plain body string, stashing the typed verdict under `result["typed_verdict"]`; `parse_review_verdict/1` prefers it, CROSS-CHECKS against the legacy `REVIEW_VERDICT:` text sentinel (agreement resolves; disagreement between two VALID channels raises loud). **Schema-FAILED envelope fallback** (Move 16a): a `status:"failed"` envelope whose `reason` is a schema-validation failure (non-object payload) falls back to `parse_review_verdict/1` against the envelope's own `value` (the prose reply survives the boundary as a string) BEFORE the failure is treated as a transport error — recovers a substantive review whose only defect was envelope shape. A reply that ALSO carries no parseable verdict line records an explicit unusable-verdict outcome (role, attempt count, decoded payload type) — never an empty-string verdict, which reads as "gate ran, said nothing." FALLBACK (no typed field, schema-less call, or unrecoverable text): `:unknown`, fails closed (transcript recovery, 1 retry, then loud error). Coverage: one `REVIEW_COVERAGE:` line per `## Files Modified` path required; missing/malformed → `:incomplete` retry budget then error. | reviewer body parse                                                                                                                                   |
| the commit + `COMMITTED: <sha>` line                              | **deterministic** — the loop shells `codegen-commit --subject <sealed>` (a script, not a role); no model call, no committer role exists. See pitch "committing is deterministic, not a model call". **Self-referential verification**: a pitch rewriting its own delivered contract (e.g., review-verdict coverage lines in `shared/rules/roles/reviewer.md` + `.md.j2` summaries) can verify via its own rendered prompt — `make install` prior to this cycle propagates the change, so the reviewer's delegation text already reflects the new rule, proving the edit reached the live agent                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | `OrchestrationLoop.run_commit_step/3` → `codegen-commit`                                                                                              |
| gate verdict clear/failed                                         | **deterministic**; `"inconclusive"` fails closed to `:failed`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `LoopGate` — see the cycle-record owner file's Gate Verdict Truth Table                                                                               |
| infra-vs-code classification                                      | **deterministic** — 6 regex signatures, default is always `:code` (never excuses a failure as infra unless matched)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `LoopGate.classify_failure/1`                                                                                                                         |
| gate-failure OWNER routing (`:code` → which role)                 | **deterministic** — a context-doc-shaped witness (`context/*.md`/`PROJECT_CONTEXT.md`) routes to `context-curator`; everything else routes to the cycle's own developer (unchanged default)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `OrchestrationLoop.default_gate_classify_fn/2` + `resolve_gate_owner/2`, reading `LoopGate.failing_check/1`                                           |
| gate-failure load-flake absorption (incl. load-starvation)        | **deterministic** — one standalone re-run of the SAME gate command before any rework attempt is consumed; green → re-run full gate once (attempt not spent), red → real routing. A `"flake-isolated:<file>"` classification (isolated single-file rerun inside the gate step already passed) is checked FIRST, same shape, before `:stale_build`/infra/code — never a standing amnesty, one grace per occurrence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | `OrchestrationLoop.do_gate_loop_flake_check/10`, `do_gate_loop_load_starvation/10`                                                                    |
| stale-`_build` gate self-heal                                     | **deterministic** — signature (≥2 distinct "module ... is not available") + count threshold; nukes `_build` roots, re-runs the FULL gate once (attempt not spent); still stale → falls through to ordinary owner rework, never re-heals the same occurrence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `LoopGate.stale_build?/1` + `OrchestrationLoop.do_gate_loop_stale_build_heal/10`                                                                      |
| claim `ready/`→`building/` (possession)                           | **deterministic** — atomic `File.rename/2`; a race loser gets ENOENT and refuses (exit 2)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `Mix.Tasks.Codegen.Loop.claim_pitch!/2`, called before `OrchestrationLoop.run/1` (source resolved by `claim_source_after_reconcile/2`, never earlier) |
| ship `ready/`\|`building/`→`shipped/`                             | **deterministic** — retire is UNCONDITIONAL on a verified landing (`record_ship` + `File.rename!` run FIRST); a dirty tree fires a LOUD non-fatal-to-the-ship exit (`4`), never a raise that strands the pitch                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | `Mix.Tasks.Codegen.Loop.ship_ready_pitch/6` + `warn_dirty_after_retire/1` (NOT `OrchestrationLoop.run/1` — a documented prior misattribution)         |
| commit verification                                               | **deterministic** — clean tree, exactly-one-commit, commit tree hash == graded tree hash                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `OrchestrationLoop` post-commit-step check                                                                                                            |
| budget cap, watchdog, lock, retries, fallback, signals, telemetry | **deterministic**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | see below                                                                                                                                             |

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
error) — that work did NOT land, so the pitch must remain dispatchable. It is DELIBERATELY NOT called
from `run_loop_catching_infra_abort/1`'s `InfraAbort` rescue, mirroring
`LoopQueueDrain.handle_infra_abort/4`'s "pitch remains untouched" posture (the box is broken; nothing
about the pitch was wrong). An infra-aborted or crashed build therefore leaves its slug in `building/`
for the rest of that run — `codegen-drain status` surfaces the count — until the next `mix
codegen.loop`/drain startup hands the stranded claim to `InterruptedCycleRecovery.reconcile/1`, which
resumes it or parks-and-requeues it to `ready/`; two or more stranded claims at once refuse loud and
wait for the operator.

**The `building/` probe is required, not cosmetic, in EVERY reader of a pitch path** — a selected pitch
is physically in `building/` for its whole cycle, so a `ready/`-only reader silently misses it. Current
inventory: `LoopQueue.write_frontmatter!/4` (the ship-time stamp) and `LoopQueueDrain.ship/6` (the
drain's non-compliance fallback ship), both of which raise without it;
`Mix.Tasks.Codegen.Loop.resolve_pitch_source/2`, which on an exact-path miss falls back to the sibling
live state (`pitch_source_at/1` → `sibling_live_state_source/1`) rather than degrading to `:literal` —
`shipped/`, `draft/` and `archive/` are deliberately never probed, and a path naming one of them is
never redirected into a live state; and, drain-side (`context/loop-queue-drain.md`),
`LoopQueueDrain.pitch_arg_for/3` (the spawned child's pitch argument, its own ready-then-building
probe), `record_queue_park_dossier/2` (the queue-fail dossier's `pitch_path`) and
`handle_nonzero_exit/8`'s post-commit-hiccup ship arm (both via `resolve_pitch_path/2`).
`LoopQueue.ordered_slugs/2` and `blocked_by_unmet_dep/3` deliberately keep reading `ready/` only — a
claimed (`building/`) pitch is invisible to selection, and a dependent whose dep is in-flight
correctly stays blocked (in-flight ≠ shipped).

**Ordering — nothing resolves a pitch source before `reconcile/1`.** Reconcile MOVES a pitch between
live states mid-run (above), so any source resolved before it is a snapshot reconcile can invalidate.
`mix codegen.loop` therefore holds exactly ONE resolution site: `claim_source_after_reconcile/2`,
called inside the reconcile continuation, returning `{source, slug}` and deriving its own fallback slug
from the argv text alone (`argv_slug/2`, no filesystem read) — `run/1` carries nothing that can go
stale. A stale snapshot fails SILENTLY: it degrades a real pitch build to `:literal`, so the cycle
refuses with "no commit subject available" though the pitch declares `commit_subject:`, and parks no
recovery dossier (`:literal` parks nothing).

## Whole-Pitch Completeness Backstop

Pre-commit, fail-closed guarantee behind "a build implements the WHOLE pitch" — never a build-time
slice, never deferred/born-dead code. `CodegenTestHarness.BornDeadDetector.check/2` greps the cycle
diff for defer markers (`not yet wired`, `future migration`, etc.) and NEW top-level entities with
zero live non-test caller AND zero registration (manifest `launchers:`, `escript: main_module`,
`settings.json` hook — the escape valve). Wired into BOTH ship floors so a drained build can't bypass
the solo raise: `OrchestrationLoop.assert_work_produced!/2` (solo, raises → loop_failed) and
`LoopQueueDrain`'s injectable `:born_dead_fn` seam (drain, routes to false-0 park-and-continue). Runs
PRE-commit — ship chokepoint unchanged, no new stranding path. This detector is the deterministic
half of "one cycle builds the WHOLE pitch"; the prose half is `developer.md` § Whole-Pitch Builds
Only (producer) and `reviewer.md` § Deliverable coverage + § No Born-Dead / Deferred Work
(Rule N) (consumer).

## Test-Coverage Deletion Floor

`CodegenTestHarness.TestCoverageFloor.check/2` is a separate, fail-closed pre-commit floor for a
different failure class: a cycle must not lower the assertion-bearing-block count of an existing
test file while its inferred subject module survives. It compares `base_sha` and `HEAD` blobs for
modified, renamed, and deleted `*_test.exs`, `*_test.sh`, `tests/test_*.py`, and `*.test.ts` paths.
Git/diff/blob-read errors are failures, not a permissive zero count. A decrease is permitted only
when the subject dies in the same diff or an added, reasoned
`test-deletion-exempt: <path> — <reason>` marker names the affected file. As with the whole-pitch
floor, BOTH ship paths enforce it: `OrchestrationLoop.assert_test_coverage_floor!/2` raises before
the solo cycle can report `loop_committed`, while `LoopQueueDrain`'s injectable
`:coverage_floor_fn` seam rejects exit-0 and committed-nonzero fallback ships into the existing
park-and-continue path. The exit-4 ship-with-warning branch remains unchanged because its child has
already passed the solo pre-commit floor.

## Per-Cycle Spend Cap

`--max-budget-usd` (CLI) → `opts[:max_budget_usd]` → `OrchestrationLoop` private `check_budget/1`.
Checked AFTER a role's cost is accumulated into telemetry (already billed — killing mid-call saves
nothing) and BEFORE the next role is invoked. `nil` (absent, default) → always `:ok`, unchanged
behavior. Present + `telemetry.cost_usd >= cap` → `{:error, "spend cap reached: ..."}`, cycle aborts
before next role. This is the PER-CYCLE cap — distinct from the queue drain's queue-wide
`CODEGEN_BUILD_QUEUE_BUDGET_USD` (see the loop-queue-drain owner file).

## Envelope Classifier

`invoke_role/4`'s `case envelope do` classifier maps `status:"failed"` straight to `{:error, reason}`
for every role — there is no per-role override, and no typed event can promote a failed envelope to
`{:ok, _}`. `role-retrospective-before-stop` forces every role to end its final turn on a mandated
`codegen-log --learned` tool call, so a role whose last turn is tool-final and text-empty classifies as
`status:"failed"` and fails the cycle loudly. That is intended: every cycle role's deliverable is
either the working tree or its own section body, both of which a genuinely-failed turn may not have
produced.

Every role transport receives `CODEGEN_CALL_OWNER_OS_PID=System.pid()` from
`run_call_split/4`. Claude's independently-sessioned guardian treats that BEAM OS PID as a lifecycle
owner: if BEAM dies while its shell dispatcher remains alive, the guardian terminates the entire
owned Claude process group before orphaned tools can mutate the checkout.

## Model Escalation Ladder

`maybe_escalate_model/5` fires ONLY on a FINAL rework attempt (not every retry): the gate-rework
owner, or the reviewer on the final allowed re-review after `CHANGES_REQUESTED`,
via `RoleResolver.resolve_escalation/2` (test-seam override: `opts[:resolve_escalation_fn]`). Returns
`{model, effort}` to escalate to, or `:none`. On escalation, logs an operator note and stashes
`{model, effort}` at `ctx.artifacts.escalated_model` for the retry's `codegen-call` invocation. See the
role-config owner file for the ladder's actual rung values.

## Same-Harness Advisor

`maybe_advise/6` fires at the give-up boundary (`do_gate_loop_rework/9`, `rework_final_gate/5`, final
reviewer re-review, `final_attempt?` true). Shells `codegen-advise --harness=<h> --cwd=<ctx.cwd>`
(seam `opts[:advisor_fn]`, arity fixed — 18 test stubs depend on it; `--cwd` REQUIRED, loop's shell
cwd is `test_harness/`). FIXED stronger-model mapping. Assembles a bounded, machine-built evidence
packet from git/gate state at `--cwd` (not the caller's text alone), returns `{diagnosis, falsifier,
next_probe, evidence_used, missing_evidence, confidence}` — packet/schema detail: `context/harnesses.md`
§ Same-Harness Advisor. Stashed at `ctx.artifacts.advisor_plan`, rendered under `## Advisor — second
opinion`. Attempt/stage rides in `opts[:advise_meta]`, never positional. Composes with escalation;
suppressed under fixed binding; failed call is ADDITIVE. Reach: auto-wiring + `advise`/
`mcp__codegen__advise` (`cwd` REQUIRED, never inherited).

## Fixed Campaign Binding (RoleModelSweep) — Overrides Escalation and Fallback

`OrchestrationLoop.resolve_fixed_binding/2` (private) reads `<BENCH_RUN_DIR>/role-model-binding.json`
once per process (cached in the process dictionary) when a `CodegenTestHarness.RoleModelSweep`
campaign has pinned this ONE role's harness/model/effort for the whole build — see
`context/test-benchmarking.md` § Role-Model-Binding Campaigns for the full campaign contract.
Present-but-invalid raises before the first role runs; absent (no `BENCH_RUN_DIR`, or no file
there) is `:none` for every role — ordinary build behavior, byte-for-byte unchanged.

A matching fixed binding wins over BOTH override mechanisms above for the target role only:

- `invoke_role/4`'s primary resolution uses the fixed tuple verbatim in place of `resolve_fn.(role, harness)`.
- `maybe_escalate_model/5` short-circuits to `ctx` unchanged (escalation suppressed) — a stuck pinned
  role never silently jumps to a stronger tier on the final gate-retry attempt.
- `handle_switch_model_failure/7` returns `{:error, "... binding fixed ... fallback suppressed for
campaign arm"}` instead of walking the `fallback:` chain — a pinned role whose model is unavailable
  reports the arm `INCONCLUSIVE` rather than silently measuring a different model.

Every non-target role, and every role when no binding file is present, is unaffected — this is
additive suppression scoped to one `{role, harness}` pair per campaign arm, never a global toggle.

`accumulate_telemetry/3`'s third argument carries the ACTUAL resolved `{harness, model, effort}` for
each invocation (whichever of the three sources above supplied it) into an additive `dispatch` field
per `per_role` entry — `emit_loop_telemetry/3` projects these as an ordered `dispatches` list;
`UsageParser.parse_dispatches/1` reads it back from raw `codegen-build` stdout. This is how a campaign
proves a role's binding was truly honored end-to-end, not just requested.

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
`shared/enforcement/seam-registry.yaml` (`build-lock-format-to-codegen-drain-status`). `codegen-drain
status`'s computed `health=` verdict (`context/deployment-topology.md`) derives from this SAME
`watcher=` signal plus live process state — `watcher=yes` (a `"queue"`-labeled live lock) contributes to
a `working` verdict; it never substitutes for a real health check, since a live watcher with an
orphaned or wedged role process still resolves to `wedged`.

## Signal Handling

`BuildSignalHandler` traps SIGINT/SIGTERM during a run and halts with exit code 130 (standard
128+SIGINT convention) rather than letting a partial cycle exit 0 or silently swallow the signal.
SIGINT itself is uncatchable inside the BEAM on every OTP release — the shared bash helper
`harnesses/shared/loop-signal-bridge.sh` (`run_supervised_loop`) owns the boundary one layer down:
it job-controls the spawn (never `exec`s), traps INT/TERM in the bash parent, and forwards a group
SIGTERM to the child — reaching this handler exactly as a direct SIGTERM would. All four bash
callers that spawn the loop (both `dispatch.sh` twins, and the `--queue` leg of both build
launchers) share this one helper — see `context/harnesses.md` § Orchestrated Build Mode and
`context/loop-queue-drain.md`.

## Warm-Resume

`resume_checkpoint/3` reads `codegen/gate-pending/cycle-state.json` for durable checkpoint (`GATED`/`REVIEWED`/`CURATED` map to resuming at reviewer/curator/commit-step). Honor when: mapped role is in this stack's roles, slug matches `opts[:slug]` (prevent pitch A's orphaned checkpoint resuming under pitch B), gate verdict non-error, tree has publishable changes, HEAD unmoved since checkpoint. Clean tree or foreign slug → full run.

## Interrupted-Cycle Recovery

Dossiers (`codegen/gate-pending/recoveries/<slug>/<tx-id>.json`) are authority for controlled terminal failures and same-slug resume. `park_failure/1` mints per failure (identity: pitch basename + scope, never branch); it is dossier-only (no `## Build failure history` row) — the caller writes one when warranted (`context/loop-queue-drain.md` § Auto-Demotion has the full call-site split). Scope is REPORT-ONLY: changed paths beyond declared `scope:` tag with `ownership: expanded` + `scope_expansion` list in build-failure row. `materialize/2` replays via checked `git diff --binary` + `apply --check`/`apply` (never checkout/reset). An incompatible preflight is written once as typed `stage: reconciliation_required`, with `reconciliation_head`, `reconciliation_reason`, and `reconciliation_paths`; later callers read that quarantine rather than retrying a raw replay. Direct builds reject it before claiming; a post-claim race restores `building/` to `ready/` without replacing the dossier. `:exact` resumes at earliest trustworthy role; `:advanced`/`:operator` reconcile at stack developer. Dossier-derived `:recovery_role` wins over on-disk checkpoint. `codegen-drain assign` refuses cross-node transfer of slug with local dossier. `write_build_result!` atomically writes `build-result.json` only when `CODEGEN_BUILD_INVOCATION_ID` is set; `codegen-build` requires match before exit 0.

## Curator-Doc Check Gates

Post-review: gate already passed, reviewer approved. Curator consumes `ev:learned` events, MUST NOT run full gate/test. Three scans via `run_curator_doc_check/6`: (1) index-parity (`context/*.md` ↔ `PROJECT_CONTEXT.md`), (2) factcheck (diff-scoped changes), (3) consumption (upstream learned events routed to docs or recorded as curator's own learned/no-learning). Violations route to repair loop (max 15 cycles); exhaustion fails loud. Pre-scan at curator-stage entry (not only after) threads violations into first prompt. Turn-0 preflight runs same index+factcheck pair before any role invokes; curator-writable violations route to bounded repair; mixed/non-writable violations abort loud.

## Infra Abort

`LoopGate.infra_abort!/2` raises `CodegenTestHarness.InfraAbort` — reserved for genuine infrastructure
failures (not code/test failures), which the loop routes distinctly from a normal gate `:failed`
verdict. See the cycle-record owner file's infra-vs-code classification section for the signature list.
Inherited orientation-doc drift raises this ONLY when at least one violated doc is outside the curator's
write surface, or the violation set is unparseable/mixed — see the Turn-0 Sibling paragraph above for the
curator-writable-only repair path that replaced the prior unconditional abort.

## Terminal Reason & Cause

`terminal_reason` (`loop_committed`/`loop_failed`) is stable; `terminal_cause` is the concrete failure reason (when applicable) — consumed by `failure_summary/1` (`context/loop-queue-drain.md`). Emission after commit verification. Gate verdict and telemetry carry `:session_id` attributed to the invoking developer role (fallback: `dev_role_from_ctx/1`), never anonymous `""`. `gate-result.sh` derives `duration_s` from ISO8601 timestamps (portable via `jq`'s `fromdateiso8601`), recording `null` when unparseable. Same emission (`emit_loop_telemetry/3`) carries a `"timeline"` block joining the three ledgers into `roles`/`preflight`/`gate`/`wall_ms`/`unaccounted_ms` — schema: `context/cycle-record.md` § Timing/Metrics Telemetry.

## Terminal Marker — Deterministic Exhaustion

`write_terminal_marker/3` writes `codegen/gate-pending/terminal-state.json` when rework loop's owning role exhausts progress+ceiling over reproduced defect (gate rework, env-var check). Durable signal: deterministic exhaustion ("cannot succeed however many runs") vs recoverable transient. Marker read BEFORE `retry_eligible?/5` routes to park+skip+circuit-breaker. Orientation-doc producers do NOT write it (scan is deterministic, re-primed second pass routinely lands). Marker write is REQUIRED (failed write raises `InfraAbort`); unlinked at FULL cycle start. Consumer: `LoopQueueDrain`.

## Trigger Keywords

orchestration loop, OrchestrationLoop, mix codegen.loop, BuildLock, BuildSignalHandler, warm-resume, resume checkpoint, escalate_model, max-budget-usd, spend cap, infra abort, LoopGate, gate verdict, LLM vs deterministic, curator doc check, index-parity, factcheck, ev:learned routing, duration_ms, telemetry, terminal marker, terminal-state.json, terminal cause, terminal reason, BEAM OS PID, CODEGEN_BUILD_INVOCATION_ID, gate failure owner, flake check, role-model-binding.json, dispatch provenance, InterruptedCycleRecovery, build-result.json, recovery dossier, reconciliation_required, recovery preflight, materialize, recovery_mode, park_failure, run_orientation_preflight, classify_orientation_violations, orientation-doc violations, curator-writable doc, maybe_advise, advisor_plan, codegen-advise, born-dead detector, defer-marker, test-coverage deletion floor, TestCoverageFloor, test-deletion-exempt, whole-pitch builds, codegen-commit, deterministic commit step, claim_source_after_reconcile, resolve_pitch_source, pitch_source_at, sibling_live_state_source, argv_slug, stale pitch source, building probe inventory, no commit subject available, stranded claim reconciled at startup
