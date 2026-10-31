# K-CHECKTIME-CLOCK measurement note

Avoidable fixed waits in `cli/build` and `cli/shape` tests were replaced by observed readiness and explicit release. Production code, timeouts, retry counts, limits and race sharding are unchanged. No test was skipped, deleted, weakened or tagged out.

## Measurement record

- Host: Apple M4 Pro, 12 CPUs, 24 GiB, Darwin 25.6.0 arm64; Go 1.27.2 darwin/arm64; `GOFLAGS=-trimpath`; `GOMAXPROCS=4` (the host's go-test check environment); no synthetic load.
- Revisions: before = `git archive` of `6612b1f716c723804ed67186bac266103920daca` (HEAD, unmodified tests) expanded into a temp directory; after = the same HEAD with this change in the working tree.
- Preparation: none beyond the Go build cache; every run uses `-count=1`, so no test result is cached.
- Commands (from `cli/`, identical before and after, run sequentially under the host's exclusive Go-suite lock `heavy.sh`, in the same shards the configured go-test check uses; `kogen/build` run as one binary can exceed the unchanged ten-minute `go test` timeout on this host, so the shards, not the timeout, are what is measured):
  1. `go test -count=1 -json ./build/ -run '^(TestClaudeLineupReviewMaterialDelivery|TestClaudeLineupReviewExactTree)$'`
  2. `go test -count=1 -json ./build/ -run '^(TestKReviewRetrySeparateAllowances|TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild)$'`
  3. `go test -count=1 -json ./build/ -skip '^(TestClaudeLineupReviewMaterialDelivery|TestClaudeLineupReviewExactTree|TestKReviewRetrySeparateAllowances|TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild)$'`
  4. `go test -count=1 -json ./shape/ -run '^Test[A-R]'`
  5. `go test -count=1 -json ./shape/ -skip '^Test[A-R]'`
- Timing and load: before 18:43:51Z-18:56:58Z (UTC), load averages 8.54/4.46/3.75 at start and 3.70/3.47/3.76 at end; after 19:06:59Z-19:14:33Z, load 3.63/4.69/4.71 at start and 3.37/4.05/4.50 at end. Other agents use this shared host, so the load differed between the runs. All ten commands exited 0. Both builds record the same two pre-existing skips (`TestNamedFeedbackBuilderRepair`, `TestNamedFeedbackCompatibility`); the before shape run records one skip that the after run does not.
- Raw `go test -json` output, per-run context and the scripts: `/tmp/k-clock-custody.wo3Hb5/{before,after}-{build-1,build-2,build-3,shape-1,shape-2}.json`, `{before,after}.context.txt`, `measure.sh`, `rank.py`, `tables.py` (a temp directory outside the checkout).
- Elapsed values are Go's per-test `Elapsed` for top-level tests; most tests run with `t.Parallel`, so they overlap and include time sharing the CPU with sibling tests. Wall clock is not their sum.
- Earlier attempts' figures (full-package runs that hit the ten-minute timeout, focused comparisons and the historical 30 Oct invalid-verdict 1m58s-5m25s and working-window 1m1s values) are not reported here and are not current measurements.

## Reading the savings

The wall-clock total fell from 13m07s to 7m34s, but most of that is not this change. Tests this change did not touch also ran faster in the second run (the invalid-verdict test 25.15s to 14.18s, `TestKReviewRetrySeparateAllowances` 22.43s to 12.83s, `TestKReviewRetryChangedCheckout` 10.58s to 4.81s, `TestKReviewRetryReviewOnlyResume` 9.83s to 4.65s); their code and waits are identical, so host load and CPU contention differ between the runs and the same noise applies to the edited fixtures. The padding this change removed is one second per `sleep 1` fixture (plus the longer probe teardown it implied) and 0.3 s for the native-shell delay; the edited fixtures' measured deltas include noise of that size or larger, so no finer attribution is claimed. No savings target applies and none is claimed beyond the measured tables.

## Ten slowest build tests (baseline ranking, top-level elapsed)

| # | Test | Before s | After s |
|---|---|---:|---:|
| 1 | TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild | 25.15 | 14.18 |
| 2 | TestKReviewRetrySeparateAllowances | 22.43 | 12.83 |
| 3 | TestAResumedFittedReviewOfALargerSourcePinsItAndDeliversIt | 18.23 | 15.33 |
| 4 | TestKRevodBOnDemandReset | 12.87 | 12.93 |
| 5 | TestChangesWhilePartsAreUnreadIsSentBackToRead | 12.20 | 9.59 |
| 6 | TestLargeSourceIsDeliveredAsPinnedPartsAndMustBeReadBeforeApproval | 10.99 | 10.61 |
| 7 | TestKReviewRetryChangedCheckout | 10.58 | 4.81 |
| 8 | TestChangesAfterEveryPartWasReadStaysBlocked | 10.41 | 9.41 |
| 9 | TestAConversationOverTheBudgetIsResetToALocalWorkingWindow | 10.16 | 10.02 |
| 10 | TestKReviewRetryReviewOnlyResume | 9.83 | 4.65 |

Required investigation inclusions:

| Test | Before s | After s | Baseline rank |
|---|---:|---:|---:|
| TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild | 25.15 | 14.18 | 1 |
| TestAConversationOverTheBudgetIsResetToALocalWorkingWindow | 10.16 | 10.02 | 9 |

## Changed build fixtures

| Test | Before s | After s |
|---|---:|---:|
| TestACommitInterruptedDuringPostcommitIsUndone | 5.71 | 1.95 |
| TestAnInterruptedStartupRestoresTheIndexAndCannotResume | 0.36 | 0.38 |
| TestResumeRefusesAnUncertainToolBoundary | 0.68 | 0.71 |
| TestAnInterruptedTargetedRepairReportsPendingReviewAndChangedVerification | 3.88 | 2.35 |
| TestAnInterruptedVerificationOfAReviewerRepairResumesWithoutANewRequest | 2.55 | 2.19 |
| TestExternalBuilderReviewStageResumes | 3.45 | 2.59 |
| TestInterruptingAStageGateRetainsNoCompletedEvidenceAndResumeRerunsSetupAndCommands | 1.14 | 1.21 |
| TestNativeRoundMapsCancellationButKeepsTheSessionsInterrupt | 0.60 | 0.35 |
| TestNativeShellContextCancellationStops | 0.33 | 0.37 |

## Changed shape/Refine fixtures (subtests indented)

| Test | Before s | After s |
|---|---:|---:|
| TestRefineCumulativeRedProposalsStayUnpublishedUntilTheirObservationsAreAcknowledged | 9.58 | 4.77 |
| TestRefineNarrowRetryPreservesAllEarlierProposalsUntilMergedReadiness | 7.11 | 3.16 |
| TestRefineFailedAndCancelledApprovedCorrectionsPreservePackageRawApprovalAndIndex/cancel | 1.99 | 1.26 |
| TestRefineFailedApprovalRevocationRestoresAReadOnlyArtifactAndRetainsApproval | 8.52 | 2.87 |
| TestRefineChangesToHeadRawApprovalOrIndexPreventApprovedPublication/head | 5.75 | 1.28 |
| TestRefineChangesToHeadRawApprovalOrIndexPreventApprovedPublication/approval | 5.83 | 2.36 |
| TestRefineChangesToHeadRawApprovalOrIndexPreventApprovedPublication/index | 4.88 | 1.73 |
| TestRefineAnExternalEditWhileRefiningIsPreservedAndPreventsPublication | 4.60 | 1.28 |
| TestRefineInterruptionDuringAProbePreservesThePackageAndRetainsEvidence/SIGINT | 1.59 | 1.21 |
| TestRefineInterruptionDuringAProbePreservesThePackageAndRetainsEvidence/SIGTERM | 1.61 | 1.19 |
| TestRefineInterruptionDuringAProbePreservesThePackageAndRetainsEvidence/SIGHUP | 1.55 | 1.19 |
| TestRefineRollsBackItsReceiptWhenTheCheckoutChangesDuringPublication | 5.28 | 1.75 |

## New readiness tests (after only)

| Test | After s |
|---|---:|
| build: TestChecktimeClockReadiness | 0.89 |
| build: TestChecktimeClockReadiness/early-exit | 0.36 |
| build: TestChecktimeClockReadiness/interrupt | 0.53 |
| shape: TestChecktimeClockReadiness | 0.00 |
| shape: TestChecktimeClockReadiness/early-exit | 2.60 |
| shape: TestChecktimeClockReadiness/release | 2.25 |

Sum of top-level test elapsed (parallel tests overlap, not wall clock): build 615 -> 423 s; shape 954 -> 401 s

The two required tests are in the first table (invalid-verdict, rank 1) and the second (working-window, rank 9): neither test nor its helpers contains a sleep or other fixed wait (checked by reading both and searching them for `Sleep`, `sleep` and `time.After`), so neither was edited and their elapsed time is not padding that could be replaced by a readiness signal.

## Wait classification

Classes: **P** fixed scheduling padding, **R** readiness/completion polling, **N** explicit negative-observation interval, **H** deliberately hanging child to interrupt, **T** real timeout/grace contract.

### Shape and Refine (`cli/shape`)

| Wait | Class | Decision and reason |
|---|---|---|
| `touch marker && sleep 1` probes in six Refine fixtures (cumulative red proposals, narrow retry, failed approval revocation, head/approval/index changes, external edit, receipt rollback) | P | Replaced by `refHeldProbe`: the real probe touches the marker, then waits for a release file. The test asserts the unpublished state or changes the checkout while the probe is held and releases only afterwards; `refineHeldAsync` also releases and joins at cleanup. |
| `touch marker && sleep 10` probes (cancel; SIGINT/SIGTERM/SIGHUP interruption) | H | Retained: the real child is killed by the interrupt, so the ten seconds never elapse. Cleanup now interrupts and joins the refinement if an assertion fails first. |
| `sleep 600` probes in `TestShapeProbeReportsTimeoutObservationFailure` and `TestRefineProbeReportsTimeoutObservationFailure` | H (never run) | Retained: `ContractProbeRun` is replaced by a stub, so the command never executes and nothing waits. |
| `refWaitFile` 10 ms poll (30 s limit) | R | Retained: observed marker polling. |
| `refWait` 60 s and provider-pause 30 s limits | T | Retained: failure watchdogs, not elapsed time on success. |
| Shape/Refine fixture client `Sleep` stub | - | Already a no-op: no retry wait. |
| Evidence clock (`NewEvidenceWithClock`, `shpClock`) | - | Existing controllable clock for evidence accounting; unchanged. |
| `cancelBatch` one-second deadline (production) | T | Production grace; untouched. |

### Build (`cli/build`)

| Wait | Class | Decision and reason |
|---|---|---|
| `time.Sleep(300ms)` before interrupting in `TestNativeRoundMapsCancellationButKeepsTheSessionsInterrupt` | P | Replaced: the shell child touches a marker and the test interrupts once `waitFor` observes it; cleanup interrupts and joins. |
| `sleep 30` children in the two native-shell cancellation tests | H | Retained; killed by the interrupt or context cancellation (cleanup joins on early exit). |
| `sleep 600` setup, post-commit hook, shell and check children (startup, post-commit, uncertain tool boundary, targeted repair, reviewer-repair verification, external-builder review stage, stage gate) | H | Retained: they end by interrupt, never by a ten-minute wait. Their marker polls (`waitFor` 20 ms, a 50 ms `sleepBriefly` loop that silently proceeded when the marker never appeared, and a 50 ms loop) became one `waitForRunning` (R): it fails at once if the Build ends first and the test's cleanup interrupts and joins a still-held Build. Each caller keeps its own unchanged failure deadline (15 s for startup, post-commit and stage gate, 10 s for the uncertain tool boundary, 30 s for the two reviewer tests, 120 s for the external-builder review stage); the two reviewer tests that silently proceeded now fail at that same deadline instead. This covers the `stages_test.go` marker (historically timed out under load): the deadline is unchanged, and only the readiness check and cleanup changed. |
| `sleep 300 &` orphan child and `deadline` / `interrupt_kills_children` conformance scripts (`sleep 20`, `cancel_after_seconds: 4`) | T / H | Retained: real process-group, cancellation and deadline evidence. |
| `silentCommand` (`sleep 2`) in `TestSilentBuildShellNotStopped` and `TestSilentReviewShellNotStopped` | N | Retained: the claim is that a silent command is not stopped, which needs elapsed silence. |
| `hang()` handler (20 s fallback) | H | Retained; ends when the client disconnects. |
| `budgetClock` / `Client.Now` in `response_budget_test.go` | - | Existing controllable clock for the response-budget policy; no real wait. |
| `statRefresh` `os.Chtimes` +2 s | - | Existing controlled time instead of waiting. |
| `k_reviewretry_cli_test.go` four-minute context | T | Retained watchdog. |

### Outside build and shape (found by verification)

| Wait | Class | Decision and reason |
|---|---|---|
| `waitFile` marker poll for the real git post-commit hook and git wrapper in `cli/git/commit_test.go` (20 ms poll, 10 s limit) | R, with a T watchdog | Verification of an earlier candidate failed once with `TestInterruptDuringCommitWaitsForGitAndUndoesALandedCommit` timing out at 10 s while the whole `kogen/git` package took 185 s beside the other shards; alone the test takes under two seconds and passes. The 10 s failure watchdog is retained unchanged (the Intent allows no timeout or limit change; a raise to 60 s in that candidate was reverted in review), so this remains a load-sensitive failure deadline. Both tests now release the held hook and join the background commit at cleanup, which previously leaked a hook that waited for a release file forever when an assertion ended the test early. |

Clocks are used only for their own policy and accounting contracts (`Client.Now`, Evidence's clock); fake clocks do not stand in for process termination or disk durability.

## Readiness tests

`TestChecktimeClockReadiness` exists in `./build` (a native shell child held until the test interrupts it) and in `./shape` (a real Refine probe held until released). Each runs a normal path and an `early-exit` path that returns while the child is still held; cleanup then interrupts or releases it and joins the run. Both packages pass them (`go test -count=1 -race -run '^TestChecktimeClockReadiness$' ./build ./shape`).
