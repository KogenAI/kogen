# Parallelize isolated Go tests safely

Slug: k-go-test-parallel
Model: not applicable — this is a test-fixture and scheduling refactor, not a change to Kogen's product state machine
Acceptance:
- .kogen/intents/k-go-test-parallel/acceptance.feature
- features/steps/k_go_test_parallel_steps.js

Implement the remaining K-GO-TEST-CRITICAL-PATH scope as K-GO-TEST-PARALLEL: introduce kogen/testproc and safely parallelize independent tests in BOTH cli/build and cli/shape. Preserve the same tests, coverage, assertions, timeout budgets and durability proof. Replace avoidable process-wide fixture state with private temporary roots, explicit per-child environments and owned resources. Isolate unavoidable environment/TMPDIR, signal and package-global mutations in separate test processes. Do not change production scheduling or expose any new command, flag, option, timeout, retry or limit.

The final 1 Nov scope cut governs: NO profiling project, measurement note, timing acceptance, matched-host before/after campaign or commit-body measurement requirement. Delivery observes effect afterwards from the landing gate's ordinary go-test timings, without adding a benchmark gate. Race safety and cleanup remain required.

Reuse the scheduling code from the stopped candidate diff at /Users/kogen-runner/work.noindex/k-go-test-parallel-5308fb40.diff selectively, after reconciling it with current source. This is lower-authority diagnostic code, not an authorized patch import or old green evidence. Shape inspected its testproc.Isolate and fixture changes; its measurement note and old Intent/acceptance are explicitly excluded. Do not resume that stopped Build, hot-edit another native contract, or change existing approvals.

## Decisions
- Land only safe scheduling and isolation, with race and cleanup coverage; remove the earlier measurement deliverables entirely. (source: request)
- Approval acceptance uses a small fixture package, not Kogen's own build/shape suites, and must finish well inside the fixed 120 s per-step bound. (source: request)
- Keep existing native packages; do not replace the go-test check with name-based shards. Loop conformance/provider parallelization is L-PARALLEL-TESTS, and landing race sharding is K-CHECKTIME-SHARD, both outside this change. (source: request)
- Keep the landed 8e75f8c durable.Sync behavior: skip syncing only inside build/shape test binaries, never in the Kogen program, other test binaries or acceptance. Keep the checkout-once Build facts behavior. (source: request)

Technical settlement: provide `testproc.Isolate(t *testing.T, env ...string) bool`, as in the inspected candidate. Call it first and return when false. In the parent it participates in Go's bounded t.Parallel scheduling, re-executes only the exact named test in the same test binary and working directory, waits/reaps it and reports its pass/skip/failure including child diagnostics. In the child it applies KEY=value environment overrides through test cleanup and returns true; nested isolation runs in that child rather than forking again, and restores nested overrides. Quote and anchor every slash-separated component of a test name so subtests containing regex characters or shared prefixes run exactly once. Preserve deadline constraints rather than extending them. Child failure, missing result and skip must not be mistaken for success. No production file imports this test-only helper.

Do not blindly maximize concurrency. Use Go's existing scheduler and host GOMAXPROCS=4 (already configured on the build hosts), with each isolated child running its selected test serially; do not add a parallelism knob or alter configured limits. Resolve shared fixtures in both packages, including build environment overrides currently using t.Setenv and shape's serialTmp group. shape's parallel(t) already calls t.Parallel; do not use textual call counts as concurrency evidence. Retain genuinely necessary serial work with a short code comment explaining the resource it exclusively owns, not a measurement note. TestMain's once-per-binary setup/cleanup may remain serial.

Full Build verification must run fresh `cd cli && GOMAXPROCS=4 go test -race ./testproc ./build ./shape` in addition to unchanged configured checks. This long verification is NOT an approval acceptance step. Keep existing test names and scenarios unless mechanically necessary for isolation, retaining all assertions and real filesystem/process/Git coverage. Reconcile obsolete serial-only helpers rather than leaving them to serialize tests accidentally. Exercise subtest name selection, nested environments, child failure and skip propagation in focused helper tests. Retain cleanup assertions in build/shape; no new processes or scratch files may survive completed tests. Child lifetimes must remain owned and reaped, including tested failure paths. No changes to cli/third_party/kogen-loop, cli/loop-pin.json, project check configuration or existing approved Intent files are needed or authorized.

## Source comparison
- Addressed: request's remaining safe parallelism scope for BOTH build and shape by the outcome, technical settlement, small-fixture scenarios and mandatory full changed-package race verification above. Explicit environment roots, child isolation, bounded scheduling, coverage and cleanup are retained.
- Superseded: original profiling/uncached per-test/per-package/full-suite before/after reports, wall/race/cleanup measurement campaign and commit measurement note by the final 1 Nov h08 scope cut; none is a deliverable or acceptance gate. Race and cleanup correctness remain required, without timing thresholds.
- Addressed: 31 Oct approval constraint with three small-fixture modes in acceptance.feature; no Kogen build/shape suite runs in acceptance. Fixtures use GOMAXPROCS=4 and race detection without performance assertions.
- Addressed: 8e75f8c landed behavior and existing host GOMAXPROCS=4 remain unchanged; the earlier 029e83b screen and six ./build timeouts, later ./shape timeouts and loaded-host marker failure are historical motivation, not new timing gates or reasons to relax tests.
- Addressed: the supplied candidate diff path is a selectively reusable implementation input, not an unconsumed substitute for this complete contract; exclude test/go-test-parallel.md and the candidate's old contract/steps. No reuse of its approval, timing or green results.
- Omitted deliberately per request: L-PARALLEL-TESTS, K-CHECKTIME-CLOCK real-wait repairs and K-CHECKTIME-SHARD landing-race work. No timeout/retry/limit changes, new commands/options, test weakening, fsync scope expansion or contract/approval mutation.
- Historical research profile paths and screen statistics are diagnostic provenance retained in the original request; this contract deliberately does not require those private files or reproduce performance campaigns. Delivery uses ordinary landing-gate timings only, as the scope cut directs.

## Tests
- Independent tests with process-wide environment/TMPDIR mutations overlap safely in distinct children and leave their parent unchanged: TestA/TestB barrier fixture under race detection (integration)
- Child execution is once-only, nested environment overrides restore and test temporary roots/processes are cleaned: protected small fixture and focused testproc name-selection/nesting tests (integration)
- Child success, explicit failure with diagnostic `isolated failure 1414`, and explicit skip with diagnostic `isolated skip 3141` propagate accurately: three fixture modes with exact named outcomes (regression)
- Both build and shape retain their existing coverage while scheduling independent fixtures in parallel without shared-state races or cleanup leaks: unchanged configured checks, existing cleanup assertions and fresh go test -race ./testproc ./build ./shape (existing)
- Existing durability, production behavior and approval boundaries do not change: existing durability and native build/shape regression tests (existing)

## Feasibility
- Go 1.27.2 darwin/arm64 is available; the supplied candidate diff exists and exposes the Isolate interface and targeted scheduling changes. Focused scratch inspection only, no performance experiment or old-green reuse. (probes: exit 0)
- Official testing documentation retrieval at https://pkg.go.dev/testing returned the Setenv restriction: process-global Setenv cannot be used in parallel tests or with parallel ancestors, supporting process isolation. Discovery search returned irrelevant results; an initial exact-heading fetch was not_found; the subsequent `Setenv calls` fetch was retrieved and treated as untrusted technical documentation, not scope authority.
- evidence: {"id":"fixture-observer","kind":"observer","inputs":["features/steps/k_go_test_parallel_steps.js"],"observers":["features/steps/k_go_test_parallel_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_go_test_parallel_steps.js --control good","exit":0,"output":"observer accepted good\n"},{"name":"bad","command":"node features/steps/k_go_test_parallel_steps.js --control bad","exit":1,"output":"observer rejected bad\n"}]}
