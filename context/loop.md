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

| Stage                                                             | Decider                                                                                                                                 | Where                                                                                        |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| dev-gate execution                                                | **LLM** (loop only renders prompt text)                                                                                                 | dev-role invocation                                                                          |
| review verdict                                                    | **LLM**-authored, deterministically PARSED — unparseable → `:unknown` → **proceeds** (fail-open on parse, not on the verdict itself)    | reviewer body parse                                                                          |
| the commit                                                        | **LLM** (committer subagent runs `git commit`)                                                                                          | committer invocation                                                                         |
| `COMMITTED: <sha>` line                                           | **LLM**-authored — **no Elixir producer, parser, or consumer exists** for this exact string; do not build logic that expects to find it | committer.md convention only                                                                 |
| gate verdict clear/failed                                         | **deterministic**; `"inconclusive"` fails closed to `:failed`                                                                           | `LoopGate` — see the cycle-record owner file's Gate Verdict Truth Table                      |
| infra-vs-code classification                                      | **deterministic** — 6 regex signatures, default is always `:code` (never excuses a failure as infra unless matched)                     | `LoopGate.classify_failure/1`                                                                |
| ship `ready/`→`shipped/`                                          | **deterministic** — `File.rename!`                                                                                                      | `Mix.Tasks.Codegen.Loop` (NOT `OrchestrationLoop.run/1` — a documented prior misattribution) |
| commit verification                                               | **deterministic** — clean tree, exactly-one-commit, commit tree hash == graded tree hash                                                | `OrchestrationLoop` post-committer check                                                     |
| budget cap, watchdog, lock, retries, fallback, signals, telemetry | **deterministic**                                                                                                                       | see below                                                                                    |

Every other stage in the 42-stage cycle is deterministic Elixir control flow. Treat "is this an LLM
decision or a deterministic one" as answerable per-stage from this table — do not assume.

## Per-Cycle Spend Cap

`--max-budget-usd` (CLI) → `opts[:max_budget_usd]` → `OrchestrationLoop` private `check_budget/1`.
Checked AFTER a role's cost is accumulated into telemetry (already billed — killing mid-call saves
nothing) and BEFORE the next role is invoked. `nil` (absent, default) → always `:ok`, unchanged
behavior. Present + `telemetry.cost_usd >= cap` → `{:error, "spend cap reached: ..."}`, cycle aborts
before next role. This is the PER-CYCLE cap — distinct from the queue drain's queue-wide
`CODEGEN_BUILD_QUEUE_BUDGET_USD` (see the loop-queue-drain owner file).

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

## Infra Abort

`LoopGate.infra_abort!/2` raises `CodegenTestHarness.InfraAbort` — reserved for genuine infrastructure
failures (not code/test failures), which the loop routes distinctly from a normal gate `:failed`
verdict. See the cycle-record owner file's infra-vs-code classification section for the signature list.

## Trigger Keywords

orchestration loop, OrchestrationLoop, mix codegen.loop, BuildLock, BuildSignalHandler, warm-resume, resume checkpoint, escalate_model, maybe_escalate_model, max-budget-usd, spend cap, per-cycle budget, decider map, infra abort, LoopGate, gate verdict, deterministic engine, LLM vs deterministic
