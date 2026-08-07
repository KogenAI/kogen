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

## The Decider Map — What Is LLM vs Deterministic (swept, exactly 2 LLM stages of 42)

| Stage                                                             | Decider                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Where                                                                                                                                         |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| dev-gate execution                                                | **LLM** (loop only renders prompt text)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | dev-role invocation                                                                                                                           |
| review verdict                                                    | **LLM**-authored, deterministically PARSED — unrecoverable/ambiguous → `:unknown`, fails closed (transcript recovery, then 1 reviewer retry, then loud error; never silently approves). The parser classifies EVERY marker-bearing line with one anchored matcher wherever it sits — terminality is NOT required — and honours the result only on unanimity; a conflicting marker, a non-enum verdict word, or a hedged prose mention stays `:unknown`. A verdict-free value is re-read from the reviewer's own transcript (assistant turns only) before any re-invocation. Before it, one `REVIEW_COVERAGE: <path> read\|skipped: <why>` per `## Files Modified` path is required; if the returned value is only a post-log sign-off, coverage is recovered from the last assistant transcript turn that satisfies the same totality check. Missing/invented/malformed coverage stays `:incomplete` → same-reviewer retry budget (`:max_review_coverage_cycles`, default 2) then error; APPROVED asserts a stated, not just any, surface. **Test-seam gap**: Grepping for `review_file_set_fn` overrides misses tests that invoke the DEFAULT function against a fixture's real git tree — correct sweep is "describe blocks that git-init a tmp dir AND stub bare REVIEW_VERDICT", not the seam name alone | reviewer body parse                                                                                                                           |
| the commit + `COMMITTED: <sha>` line                              | **deterministic** — the loop shells `codegen-commit --subject <sealed>` (a script, not a role); no model call, no committer role exists. See pitch "committing is deterministic, not a model call". **Self-referential verification**: a pitch rewriting its own delivered contract (e.g., review-verdict coverage lines in `shared/rules/roles/reviewer.md` + `.md.j2` summaries) can verify via its own rendered prompt — `make install` prior to this cycle propagates the change, so the reviewer's delegation text already reflects the new rule, proving the edit reached the live agent                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `OrchestrationLoop.run_commit_step/3` → `codegen-commit`                                                                                      |
| gate verdict clear/failed                                         | **deterministic**; `"inconclusive"` fails closed to `:failed`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `LoopGate` — see the cycle-record owner file's Gate Verdict Truth Table                                                                       |
| infra-vs-code classification                                      | **deterministic** — 6 regex signatures, default is always `:code` (never excuses a failure as infra unless matched)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `LoopGate.classify_failure/1`                                                                                                                 |
| gate-failure OWNER routing (`:code` → which role)                 | **deterministic** — a context-doc-shaped witness (`context/*.md`/`PROJECT_CONTEXT.md`) routes to `context-curator`; everything else routes to the cycle's own developer (unchanged default)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `OrchestrationLoop.default_gate_classify_fn/2` + `resolve_gate_owner/2`, reading `LoopGate.failing_check/1`                                   |
| gate-failure load-flake absorption                                | **deterministic** — one standalone re-run of the SAME gate command before any rework attempt is consumed; green → re-run full gate once (attempt not spent), red → real routing                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | `OrchestrationLoop.do_gate_loop_flake_check/10`                                                                                               |
| stale-`_build` gate self-heal                                     | **deterministic** — signature (≥2 distinct "module ... is not available") + count threshold; nukes `_build` roots, re-runs the FULL gate once (attempt not spent); still stale → falls through to ordinary owner rework, never re-heals the same occurrence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `LoopGate.stale_build?/1` + `OrchestrationLoop.do_gate_loop_stale_build_heal/10`                                                              |
| claim `ready/`→`building/` (possession)                           | **deterministic** — atomic `File.rename/2`; a race loser gets ENOENT and refuses (exit 2)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `Mix.Tasks.Codegen.Loop.claim_pitch!/2`, called before `OrchestrationLoop.run/1`                                                              |
| ship `ready/`\|`building/`→`shipped/`                             | **deterministic** — retire is UNCONDITIONAL on a verified landing (`record_ship` + `File.rename!` run FIRST); a dirty tree fires a LOUD non-fatal-to-the-ship exit (`4`), never a raise that strands the pitch                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `Mix.Tasks.Codegen.Loop.ship_ready_pitch/6` + `warn_dirty_after_retire/1` (NOT `OrchestrationLoop.run/1` — a documented prior misattribution) |
| commit verification                                               | **deterministic** — clean tree, exactly-one-commit, commit tree hash == graded tree hash                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | `OrchestrationLoop` post-commit-step check                                                                                                    |
| budget cap, watchdog, lock, retries, fallback, signals, telemetry | **deterministic**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | see below                                                                                                                                     |

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

`maybe_advise/5` fires at the SAME give-up boundary as `maybe_escalate_model/5` (both
`do_gate_loop_rework/9`, `rework_final_gate/5`, and the final reviewer re-review after
`CHANGES_REQUESTED` (`final_attempt?` true), immediately after
escalation. Shells `codegen-advise --harness=<current build harness>` (test-seam: `opts[:advisor_fn]`,
default `default_advisor_fn/3`) with the rework reason + brief. `codegen-advise` uses a FIXED,
stronger-model mapping in the SAME harness (`claude_code` → `claude_code`/`opus`; not configurable)
and returns `{plan, confidence}` JSON, stashed at
`ctx.artifacts.advisor_plan` and rendered under `## Advisor` for the reworked developer or final
reviewer role. Composes
with escalation (both `:escalated_model` and `:advisor_plan` can coexist; both cleared once resolved).
Suppressed under a fixed campaign binding (mirrors `maybe_escalate_model/5`). Failed/unavailable call
is ADDITIVE-failure — `ctx` passes through unchanged; advice is help, never a gate. Reach paths: (1)
this auto-wiring; (2) the `advise`/`mcp__codegen__advise` tool on developer roles for self-invoke —
same binary/mapping, harness-specific `current` baked at the tool layer.

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
per `per_role` entry — `emit_loop_telemetry/1` projects these as an ordered `dispatches` list;
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

`resume_checkpoint/3` inspects `codegen/gate-pending/cycle-state.json` for a durable checkpoint
(`GATED`/`REVIEWED`/`CURATED` states map to resuming at `reviewer`/`context-curator`/the commit step
respectively via `resume_role_for_state/1`). A resume is honored ONLY when ALL of: the mapped resume
role/step is present in `roles` for this stack, **the checkpoint's stamped `slug` matches this cycle's
`opts[:slug]` (identity guard — prevents pitch A's orphaned checkpoint from being resumed by pitch B)**,
the gate verdict at checkpoint time reads as non-error (missing verdict is NOT silently treated as clear —
an explicit check), the matched tree still has publishable working-tree changes (a clean tree restarts
instead of entering reviewer/curator with no diff), and `resume_head_unmoved?/2` confirms HEAD hasn't
moved since the checkpoint (stale checkpoint after an external commit → full run, never a corrupt
resume). Resume replaces the full pitch/plan prompt with a continuation prompt (the resumed session
already carries prior tool-call history in its transcript). An empty or foreign slug → full run, never
resume.

## Interrupted-Cycle Recovery

`CodegenTestHarness.InterruptedCycleRecovery.reconcile/1` recovers a killed loop's sole
`codegen/pitches/building/*.md` claim before the NEXT cycle spawns any role — informational only, never a
selection veto. Returns `{:ok, :none}` / `{:ok, {:resume, slug}}` / `{:ok, {:requeued, slug, recovery}}` /
`{:error, reason}`; the legacy `interrupted-recovery.json` journal and its 4-stage machine
(`parking`→`parked`→`history_written`→`resume_pending`, transaction-identity-checked) are unchanged for
this narrow stranded-claim case.

**Per-transaction dossiers** (`codegen/gate-pending/recoveries/<slug>/<transaction-id>.json`, see pitch
"restarted builds resume owned work") are the authority for CONTROLLED terminal failures (direct or
queue) and same-slug resume. `park_failure/1` mints one dossier per failure (stages
`parking`→`parked`→`history_written`→`ready`→`materialized`/`superseded`→`completed`); identity is the
CLAIMED pitch's own basename + `scope:`, never branch name. Scope is REPORT-ONLY at every recovery
stage: changed paths beyond the pitch's declared `scope:` tag `ownership: "expanded"` plus
`scope_expansion: [paths]` and name those paths in the pitch's build-failure history row — they never
restrict materialization, because the REVIEWER adjudicates scope expansion and planning cannot enumerate
every line an implementation needs. An unreadable/unparseable pitch tags `ownership: "unknown"` and
likewise still materializes. One active dossier per slug; a repeat failure chains a superseding
transaction, never overwrites.

`materialize/2` resolves the slug's active dossier (reselecting that slug IS adoption) and replays it via
CHECKED `git diff --binary` + `apply --check`/`apply` — never checkout/reset/HEAD-move. `:exact` (HEAD ==
source base, tree byte-identical) resumes at the earliest trustworthy role
(`resume_role_for_recovery/3`: GATED→reviewer, REVIEWED→curator, CURATED→the commit step, else→developer);
`:advanced`/`:operator` (moved HEAD / any dirty tree, parked onto a second
`recovery/operator/<slug>/<ts>` ref first — including operator bytes beyond the declared scope, which are
preserved and recorded as `operator_ownership`/`operator_scope_expansion`, never refused) reconcile at
the stack's developer (`resolve_developer_role/1`
— the first `developer-*` role in the sequence, both stacks); a missing/moved ref, non-descendant HEAD,
conflicting apply, or an already-materialized dossier refuses non-zero, ref/checkout untouched. A
dossier-derived `:recovery_role` wins over any on-disk checkpoint because materialization is newer;
`park_failure/1` clears retired checkpoint files before its dossier becomes ready. `run/1`'s
`:recovery_mode` opt bypasses `preflight_clean_tree!/1` ONLY for a materialized run. `complete_transaction!/2` retires the
dossier after the ordinary post-commit-step commit/tree/gate verification — the recovery commit stays
backup evidence, never a second publish.

`codegen-drain assign` refuses (exit 1) a cross-node transfer of a slug with a local dossier — machine-
local state, not part of pitch-file transfer; same-node placement stays a no-op.

`OrchestrationLoop.with_startup_guard/2` wraps solo `BuildLock` acquisition/reclaim/orphan-refusal AROUND
this step. The solo Mix task passes `build_lock_held: true` so the lock is acquired once. Queue startup
recovers at the equivalent `with`-chain point — see `context/loop-queue-drain.md`.

After a verified commit, `write_build_result!/3` atomically writes
`codegen/gate-pending/build-result.json` (`invocation_id`, `slug`, `status: success`, `head`,
`updated_at`) ONLY when `CODEGEN_BUILD_INVOCATION_ID` is set (the wrapper's mktemp'd single-flight
sentinel) — absent the env var, it is a no-op, never a fabricated success record. `codegen-build` reads
this file back and requires its `invocation_id`/`slug`/`head` to match the CURRENT dispatch plus a clear
`gate-result.json` before exiting 0 — see `context/harnesses.md` § Orchestrated Build Mode.

## Curator-Doc Check (Three Legs)

The post-review curator delegation carries an authoritative stage block: the loop gate already passed
for the exact tree and the reviewer approved it; the curator consumes typed `ev:learned` events and
MUST NOT run the full gate/test command. Targeted routing/factcheck checks remain allowed. Formatting
and the three scans below are loop-owned, and `ensure_gate_graded_this_tree!` still re-gates before
the commit step whenever curator edits change the tree. Turn-0 orientation repair does not receive this
post-review claim; a resumed `REVIEWED` checkpoint does.

**Pre-scan at curator-stage entry (first-prompt seed) + post-turn backstop**: the `run_roles/4`
`context-curator` clause runs the SAME scan (`run_curator_doc_scan/2`) BEFORE the first curator
invocation, not only after it. A violation already present at curator-stage entry (from earlier
developer/reviewer edits this cycle) is threaded straight into the FIRST curator prompt via the shared
`run_orientation_repair/1` engine (same floor/progress/ceiling bound the post-turn leg uses) — one paid
call instead of an empty first call plus a second rework respawn. `:infra`-classified violations abort
loud (`LoopGate.infra_abort!/2`) before any invocation. `run_curator_doc_check/6` (below) remains the
AUTHORITATIVE post-turn backstop, unconditionally, for drift the curator's OWN edits introduce this turn
— the pre-scan only changes WHEN an already-present violation first reaches a curator prompt, never what
counts as a violation or how repair is bounded. See pitch `a-deterministic-doc-check-costs-no-extra-turn`.

`run_curator_doc_check/6` shells `default_curator_doc_scan/2`
(dispatched via the `:curator_doc_check_fn` seam, still arity-1 for the 30+ existing test overrides —
the default closure captures `gate_opts(opts)` itself, since this step runs upstream of
`run_gate_once/2`'s own `gate_opts/1` call and has to resolve `:cycle_log` on its own). Three checks,
joined into one violations message via `combine_curator_doc_results/2` folded twice:

1. **Index-parity** (`context-index-parity-scan.sh <cwd>`) — cross-file `context/*.md` add/delete vs
   `PROJECT_CONTEXT.md` § Domain Context Files parity.
2. **Factcheck backstop** (`context-factcheck-scan.sh <cwd> <doc>...`) — diff-scoped to this cycle's own
   `changed_orientation_docs/1`; catches a Bash write the PreToolUse edit-gate hook never saw.
3. **Consumption check** (`curator-consumption-scan.sh <cwd> <cycle_log>`) — asserts that when this
   cycle captured upstream `{"ev":"learned"}` events (developer/reviewer), the curator either
   routed at least one into a durable doc (working-tree diff or untracked file matching
   `^(context/[^/]+\.md|shared/rules/.*\.md)$`) or recorded the drop as its own `{"ev":"learned"}`
   event. The curator rule (`shared/rules/roles/context-curator.md` § Constraints) now MANDATES this
   recorded drop whenever nothing gets routed — a silent drop is a rule violation, not the accepted norm
   — so the scan is satisfiable on the curator's first turn instead of a rework round-trip.
   **Path-filter trap**: curator edits are conventionally spelled `codegen/rules/**`, but that is a
   symlink into `shared/rules/` and `/codegen/` is gitignored — `git` NEVER reports that spelling
   (`git check-ignore` errors "pathspec is beyond a symbolic link"). Filters against `git diff`/`ls-files`
   output MUST use `shared/rules/**` or match nothing and pass vacuously. `opts[:cycle_log]` nil (most
   unit tests) skips this leg with `{:clean}`; present-but-unreadable is fail-closed (exit 1). See pitch
   `no-role-work-recorded-without-its-learning`.

Violations from any leg that are NOT classified `:infra` (`LoopGate.classify_failure/1`) route into the
progress-bounded rework loop (`:max_curator_doc_cycles`, floor 1, ceiling 15 via `repair_allowed?/4`);
`:infra`-classified violations raise `LoopGate.infra_abort!/2` immediately (unsatisfiable by any curator
edit). Budget exhaustion fails the cycle LOUD (`curator_doc_check_exhausted/3`) — the curator is the only
role that may edit `context/*.md`, so a violation it did not clear must not travel onward as if it had
been fixed. Exhaustion writes NO terminal marker: the cycle fails but stays retry-eligible, because the
curator owns every path the scan can name and a second pass routinely clears what one bounded pass did
not. Compare the gate's `verdict=failed` marker, which is kept — a red gate is a reproduced defect.

### Turn-0 Sibling — Inherited Orientation-Doc Drift

`OrchestrationLoop.run_orientation_preflight/4` runs the SAME index-parity + factcheck scan pair at turn
0, before any role is invoked or paid for (see `:orientation_preflight_fn` moduledoc doc, and
`default_orientation_preflight/1`). A `{:violations, v}` result is CLASSIFIED
(`classify_orientation_violations/1`): when every line names a curator-writable doc
(`context/<basename>.md` or `PROJECT_CONTEXT.md`), the loop lazily resolves `context-curator`
(`preflight_roles!/3`) and runs a BOUNDED repair loop via the SHARED `run_orientation_repair/1` engine
(the same floor/progress/ceiling bound and prompt artifact this section's post-curator check uses) —
never advancing `CURATED`. Any other shape — a line naming `AGENTS.md`/`CLAUDE.md`/another surface, an
unparseable line, or a MIXED writable/non-writable set — still raises `InfraAbort` unconditionally: NEVER
a partial repair. Repair failure (invocation error, no-progress, or ceiling exhaustion) returns a
deterministic `{:error, _}`, never `InfraAbort` — and, like its post-curator sibling, writes NO terminal
marker, so the pitch stays retry-eligible instead of being parked.

## Infra Abort

`LoopGate.infra_abort!/2` raises `CodegenTestHarness.InfraAbort` — reserved for genuine infrastructure
failures (not code/test failures), which the loop routes distinctly from a normal gate `:failed`
verdict. See the cycle-record owner file's infra-vs-code classification section for the signature list.
Inherited orientation-doc drift raises this ONLY when at least one violated doc is outside the curator's
write surface, or the violation set is unparseable/mixed — see the Turn-0 Sibling paragraph above for the
curator-writable-only repair path that replaced the prior unconditional abort.

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
progress+ceiling bound over a REPRODUCED DEFECT — gate rework (`do_gate_loop_rework/9`) and the env-var
check (`run_env_var_step_rework/9`) — immediately alongside the `{:error, ...}` it already returns. This
DOES NOT change the `{:error}`/exit-1 return value; it is a durable, additional signal distinguishing a
DETERMINISTIC exhaustion ("this cycle cannot succeed however many times you run it") from a RECOVERABLE
transient exit (a process death mid-cycle).

The two orientation-doc producers deliberately do NOT write it. `curator_doc_check_exhausted/3` and
`turn0_repair_exhausted/3` return their `{:error, ...}` unmarked: a marker is read BEFORE
`retry_eligible?/5` and routes straight to park + skip + circuit breaker, and documentation drift has not
earned that claim — the curator writes every path the scan can name, the scan is deterministic over the
tree, and a re-primed second pass routinely lands what one bounded pass did not.

Deliberately NOT `InfraAbort`/exit 3 on a SUCCESSFUL exhaustion write: every marker-writing caller is
PITCH-SPECIFIC (this cycle's own gate/doc/env/orientation exhaustion) — the next pitch in a drain is
unaffected, so the queue should skip and continue rather than HALT. Exit 3 stays reserved for genuinely
repo-wide infra faults (see Infra Abort above). The marker WRITE ITSELF, however, is REQUIRED, not
best-effort: a failed `mkdir`/`File.write` now raises `InfraAbort` (`"terminal-marker-write"`) rather than
degrading to a stderr note — `LoopQueueDrain` reads this marker BEFORE `retry_eligible?/5`, so a silently
lost write would leave a deterministic exhaustion unmarked and risk a blind full-price queue retry.

The marker is unlinked at the start of every FULL (non-resumed) cycle — see `run_body/1`'s `:full`
branch — so a stale marker from an earlier, already-concluded cycle never leaks into a fresh one.
`LoopQueueDrain` is the consumer: see the loop-queue-drain owner file's "Deterministic Failure — Skip"
section for how a marked nonzero exit routes to park+skip+breaker instead of `retry_eligible?/5`.

## Trigger Keywords

orchestration loop, OrchestrationLoop, mix codegen.loop, BuildLock, BuildSignalHandler, warm-resume, resume checkpoint, escalate_model, maybe_escalate_model, max-budget-usd, spend cap, per-cycle budget, decider map, infra abort, LoopGate, gate verdict, deterministic engine, LLM vs deterministic, curator doc check, curator consumption scan, index-parity, factcheck, learnings consumed, ev:learned routing, cycle-summary timing, duration_ms, latency_ms, t_opt_int, gate session_id, duration_s, telemetry, terminal marker, terminal-state.json, owner routing, BEAM OS PID, CODEGEN_CALL_OWNER_OS_PID, CODEGEN_BUILD_INVOCATION_ID, gate failure owner, flake check, load flake, resolve_fixed_binding, role-model-binding.json, fixed campaign binding, dispatch provenance, accumulate_telemetry, dispatches, fallback suppressed, escalation suppressed, InterruptedCycleRecovery, interrupted-recovery.json, build-result.json, with_startup_guard, park_worktree, recovery journal, recovery dossier, recoveries/<slug>/<txid>.json, schema_version, dossier stages, transaction identity, materialize, resume_role_for_recovery, recovery_mode, park_failure, recovery/interrupted branch, recovery/operator branch, stranded building claim, run_orientation_preflight, run_orientation_repair, classify_orientation_violations, orientation-doc violations to fix, curator-writable doc, turn0_repair_exhausted, orientation-preflight-routes-to-curator, post-review curator gate ownership, maybe_advise, advisor_plan, codegen-advise, same-harness advisor, stuck build second opinion, advise tool, `mcp__codegen__advise`, born-dead detector, borndeaddetector, defer-marker, sub-slice forbidden, whole-pitch builds, whole-pitch completeness backstop, codegen-commit, deterministic commit step, run_commit_step
