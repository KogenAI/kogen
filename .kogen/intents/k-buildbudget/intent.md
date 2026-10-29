# Bound total builder requests per Build

Slug: k-buildbudget
Model: .kogen/intents/k-buildbudget/model.qnt invariants=bounded,stopAtLimit seed=17 samples=100 steps=30
Acceptance:
- .kogen/intents/k-buildbudget/acceptance.feature
- features/steps/k_buildbudget_steps.js

Add internal Go Deps.BuildRequestBudget integer, default zero, with native-builder-only exposure. No CLI command/flag, environment setting or project.yaml key. Positive N allows N builder attempts over the whole Build across all verification passes and explicit resumes. Exclude Review and reviewer repairs; external executors remain unchanged.

Before builder request N+1, stop with candidate/build_request_budget, exit 1. Record one build_request_budget event per stop with role=build, count=N, limit=N. Preserve candidate, checkpoint, approval and evidence; do not commit. Complete response/tool batches normally. Finish on request N may verify, review and land if no further builder request is needed.

Persist enabled limit and count in checkpoint; restore both on resume even if resume Deps omits the option. Exhausted resume sends zero more requests. Count attempts at the existing durable request-attempt boundary before dispatch, including failed/interrupted requests; context/validation refusal before dispatch is not an attempt. Keep uncertain-tool resume refusal rules. Passes, stages, working windows and resumed lineage never reset the count. Fresh Builds start at zero. Compatible checkpoints lacking these optional fields mean disabled. When off, omit new zero fields and avoid budget bookkeeping; preserve existing bytes in prompts, transport, events and checkpoints, and existing stop behavior.

## Decisions
- Default off, internal only, cumulative checkpoint count and distinct stop preserving work (source: request)
- Exclude Review because Request already distinguishes build owner naturally (source: request)
- Preserve all other limits; raise no timeout or limit default (source: request)
- Tests use temp repositories and local providers, no synthetic CPU load, and stop only child pids they started (source: request)

## Source comparison
- Addressed: request What 1–3 and Acceptance by cumulative admission, durable attempts, event/outcome and tests below; Must stay by disabled-byte equivalence, review exclusion and unchanged limits.
- Addressed: Host safety and literal slug k-buildbudget and paths features/steps/ and .kogen/intents/k-buildbudget/.
- Retained as historical motivation, not fresh measurements: LOOP-BOUNDS-1 step 0, outputs/_internal/LOOP-BOUNDS-STEP0.md, 28 Oct 2026; witness limit 32, 16 requests over 4 passes ending no_progress without any round limit; passing median 5/p99 32; estimated 38% input and 42% wall reduction and 0.98% passing-cell stops. Deterministic multi-pass tests reproduce the structural issue with smaller budgets, not research statistics. No default 32 is introduced.
- Omitted: no requested product behavior. No superseded limits or conflicts. Native-only follows the request rather than extending external executor protocols.

## Tests
- Cumulative admission and boundaries: TestBuildRequestBudgetAcrossPasses uses N=1,2,4 and focused admission assertions for N-1 allowed, N allowed, N+1 blocked, finish-at-N allowed and exact event fields (unit)
- Whole Build over multiple verification passes: TestBuildRequestBudgetAcrossPasses uses existing newEnv scripted provider and real Build entry with failed verification feedback, checking sent requests, outcome, unchanged HEAD and retained candidate (integration)
- Durable interruption/resume: TestBuildRequestBudgetResume interrupts after k=2 of N=4 attempts, reads actual checkpoint and resumes via existing Resume with omitted option, sends exactly two more, rejects the fifth and sends zero on exhausted repeat resume while retaining prior evidence (integration)
- Disabled byte equivalence: TestBuildRequestBudgetOff compares omitted and explicit zero, normalizing only existing nondeterministic run identities, asserting exact remaining prompt/request/event/checkpoint bytes, absent budget fields/events and completion beyond four requests (regression)
- Excluded Review and unchanged other limits: TestBuildRequestBudgetReview allows review after final permitted builder request (integration)
- Configured commands: all format, compile, test, go-test, spec and cucumber checks remain passing (existing)

## Feasibility
- Quint typecheck succeeded in scratch, exit 0 in 0.5 seconds; initial absolute scratch path was refused before execution and corrected to relative path.
