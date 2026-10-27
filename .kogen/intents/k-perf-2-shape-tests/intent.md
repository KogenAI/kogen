# Speed up the kogen/shape tests

Slug: k-perf-2-shape-tests
Model: not applicable — a test-suite and memoization change with no meaningful state
Acceptance:
- .kogen/intents/k-perf-2-shape-tests/acceptance.feature
- features/steps/k_perf_2_shape_tests_steps.js

`go test -race -count=1 ./...` in `cli`: package `kogen/shape` took 131–140 s on eu2 (2 CPUs) and hit the 10-minute timeout on the Mac Studio under load. The slow package stalls every Kogen build's verification. Make it take at most half of that (at most 65 s package time with `GOMAXPROCS=2 -race`, measured with the same command before and after in the Build) by removing repeated work, keeping every test and assertion.

Profile (see Feasibility): 222 top-level tests, none uses `t.Parallel`; the package spends its time in about 19,600 `git` subprocesses, repeated fixture construction (`newShpFx`: git init/config/add/commit; `newRefFx`: a full `verify.Readiness.Check` per test, though the acceptance runner is a stub script), and race-instrumented Go. Per-test top: three tests at 6–7 s, then a long tail of 1–4 s tests (Refine fixtures).

Expected remedies, to apply where the profile shows them:
- build the ready fixture state once per package (TestMain or `sync.Once`) and copy it per test instead of re-running readiness, git init, commit and sign-in;
- memoize git facts that do not change during a test (git dir, index path, toplevel) per `git.Repo`, only where provably equivalent;
- smaller fixtures or a git worktree instead of copying whole checkouts;
- `t.Parallel` for tests sharing no process-wide state (note `t.Setenv` in `newShpFx` forbids it; replace with per-fixture environment where safe).

Must stay: no timeout, retry or limit raised (including `go test -timeout`, and the `go-test` check command in `.kogen/project.yaml` unchanged); no test removed, weakened, skipped or tagged away (the two existing conditional `t.Skip` calls in `contract_test.go` stay as they are); test count and names unchanged; production behaviour unchanged except provably equivalent memoization. Host safety: never stop processes by name or pattern, only pids you started; random free high ports; synthetic tokens only; no synthetic CPU load.

## Decisions
- Package time budget is at most 65 s (half of the lower bound 131 s) measured as the package elapsed time of `GOMAXPROCS=2 go test -race -count=1 -json ./shape`. (source: request)
- Go test files and non-test Go code are not protected; the Build edits them. Only the acceptance feature and its step file are protected. (source: request)

## Source comparison
- Profile first and record top items: addressed in Feasibility (shaper's profile); the Build re-measures before/after with the same command.
- Remove repeated work (shared ready state, git memoization, smaller scratch fixtures, t.Parallel): addressed as expected remedies in prose; the speed result is the contract.
- Same coverage, nothing skipped/deleted/tagged: addressed by scenarios 1–3 (names hash and count, skip/tag count, every listed test passed).
- No timeout/retry/limit raised: addressed by scenario 2 (go-test command unchanged, no -timeout in configuration).
- Halve 131–140 s on eu2: addressed by scenario 3 with an absolute 65 s package time; the shaper host baseline was 100–114 s. Host load can add noise; omitted: Mac Studio measurement.
- Host safety rules: restated in prose; not executable.
- "All configured checks pass": covered by normal Build verification.

## Tests
- Test count and names unchanged: scenario compares `go test -list` count and hash (integration)
- No timeout added, no skips added, no build tags: scenario 2 inspects configuration and test sources (integration)
- Shape package is fast and all tests pass unskipped: scenario 3 runs the real command (scenario)
- Memoized git facts per Repo are equivalent: existing git and shape tests pass unchanged (existing)

## Feasibility
- Profile on the shaper host (4 cores, GOMAXPROCS=2, -race): package 100–114 s; sum of per-test times 131.7 s over 344 test events; slowest: TestAShapeConversationKeepsItsIdentityAcrossAWorkingWindowReset 7.0 s, TestASnapshotDamagedByACompletedToolRefusesTheNextToolInTheSameBatch 6.8 s, TestCustodyDamagedDuringFinalReadinessCannotPublishSuccessfulEvidence 6.4 s, TestRefineChangesToHeadRawApprovalOrIndexPreventApprovedPublication 4.2 s, TestRefineLargeRepositoryUsesNavigationAndKeepsCompleteOwnedAuthority 4.0 s, TestShapeSubmissionEnvelopeProblems 3.3 s, then many Refine/lineup tests at 1.2–1.9 s. (probe 1: exit 0, 112.6 s)
- A PATH git wrapper counted 19,647 git invocations during one run of the package (114 s); the fixtures' acceptance runner is a stub shell script, so node/cucumber startups are not in this package's time. No test calls t.Parallel. (probe 2: exit 0, 125.6 s)
- `go test -list . ./shape` gives 222 tests; md5 of the JS-sorted names plus trailing newline is 08e51876f8a3812da38ec3e97e7b0e38 (observed by the readiness run and probe 3: exit 0, 4.6 s); the two `t.Skip` calls are conditional in contract_test.go.
