# Remove avoidable test clock waits

Slug: k-checktime-clock
Model: not applicable — test scheduling is refactored without changing product state or time policies
Acceptance:
- .kogen/intents/k-checktime-clock/acceptance.feature
- features/steps/k_checktime_clock_steps.js

Deliver K-CHECKTIME-CLOCK, the second half of K-CHECKTIME after K-CHECKTIME-SHARD, against Studio kogen checktime-slow-test-clocks r2. Investigate measured avoidable elapsed waits across cli/build and cli/shape (including Refine and shell-generated fixtures). Replace arbitrary start delays with observed readiness and use existing controllable time for time-policy tests where valid. Do not parallelize or change race sharding. No new command, flag, option, production abstraction solely for mocking, or timeout/retry/limit change. Production behavior is unchanged.

Before editing, measure uncached Go JSON test runs on this host and preserve raw results outside the checkout in temp custody. Rank the ten slowest build tests (top-level elapsed, with relevant subtests identified separately); include TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild and TestAConversationOverTheBudgetIsResetToALocalWorkingWindow in the investigation even if no longer in the top ten. Audit both Go waits and shell waits, including sleep 1 / sleep 10 Refine probes and sleep 600 build/shape interrupt children. Classify every examined wait as fixed scheduling padding, readiness/completion polling, explicit negative-observation interval, deliberately hanging child to interrupt, or real timeout/grace contract. Record retention/replacement and reason. Do not infer elapsed savings from grep counts or watchdog durations: sleep 600 normally ends by cancellation, not a ten-minute successful wait.

Use explicit readiness/release synchronization for probes that hold the run while assertions inspect unpublished state; release only after those assertions and always release/cancel during cleanup. Preserve failure-path cleanup. Keep real OS/process/cancellation/timeout/durability evidence, negative controls and the assertions each existing test proves. Never skip, delete, weaken or tag out tests to improve timing. Existing controllable clocks include Client.Now and Evidence's clock; these are suitable only for their own policy/accounting contracts, not fake process termination or disk durability. Retain genuine real-time contracts where required. Inspect stages_test.go marker readiness (historical stages_test.go:271 timed out under load); replace timing-dependent starts rather than increasing its deadline.

After editing, repeat the same uncached measurement commands on the same host with the same toolchain and scheduling settings. Record host/load context, preparation, commands, revisions and raw result locations. The commit body must contain the baseline top-ten build test names with before/after elapsed seconds, every changed shape/Refine fixture with before/after elapsed seconds, and the classifications of all examined waits, including retained waits. Report actual measured savings, even zero or regressions, not an invented speed target. A retained measurement note in test/checktime-clock.md supplies this material before commit and must be reflected in the commit body. Do not claim the historical 30 Oct 1m58s–5m25s invalid-verdict or 1m1s working-window timings are current measurements.

All configured checks must pass, including the already-configured sharded race pass. Keep configuration and protected Loop sources unchanged. Loop's matching wait audit belongs to L-PARALLEL-TESTS and is out of scope. Shared-host safety: temp dirs only for experiments and measurement custody, no synthetic CPU load, never stop processes by name or pattern; signal only pids/process groups started by the test.

## Decisions
- Preserve every existing test's evidence, including negative observation and truthful cleanup; optimize avoidable waits, not timeouts or execution limits. (source: request)
- Measure build and changed shape fixtures before and after on one host and publish the detailed accounting in the commit body. No numerical savings target is imposed. (source: request)
- Keep this work separate from sharding, parallelization and Loop's L-PARALLEL-TESTS audit. (source: request)

## Source comparison
- Addressed: request Need and Acceptance are covered by the investigation, synchronization, preservation, measurement and final-check requirements above and the executable scenarios below. The commit-body requirement is retained, with test/checktime-clock.md providing reviewable pre-commit evidence rather than replacing it.
- Addressed: source examples sleep 1, sleep 10, sleep 600, the two named slow tests and stages_test.go:271 are explicit audit inputs; the historical elapsed values remain historical, and cancellation watchdogs are not counted as elapsed savings.
- Addressed: request change_type fix, slug k-checktime-clock, Studio kogen checktime-slow-test-clocks r2, K-CHECKTIME-SHARD prerequisite, unchanged timeout/retry/limit values and host safety are retained in this complete contract.
- Omitted: no requested behavior. Superseded: arbitrary scheduling pads only where replaced by equivalent observed synchronization. Conflicting: none. Loop changes and parallelization are explicitly excluded as requested.

## Tests
- Replace scheduling races with observed readiness while preserving unpublished-state and cancellation assertions: update affected build and shape integration tests and add TestChecktimeClockReadiness in each package to exercise the replacement's readiness, held-state observation and cleanup on an assertion/early-exit path (regression)
- Preserve real process, cancellation, timeout, durability and negative controls: run all affected original tests and all configured checks, including the sharded race pass (existing)
- Establish elapsed savings honestly: capture matched uncached before/after build and shape measurements and publish the top-ten, changed-fixture and wait-classification accounting in test/checktime-clock.md and the commit body (integration)

## Feasibility
- evidence: {"id":"clock-observer","kind":"observer","inputs":["features/steps/k_checktime_clock_steps.js"],"observers":["features/steps/k_checktime_clock_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_checktime_clock_steps.js --control good","exit":0,"output":"clock observer accepted good\n"},{"name":"bad","command":"node features/steps/k_checktime_clock_steps.js --control bad","exit":1,"output":"clock observer rejected bad\n"}]}
