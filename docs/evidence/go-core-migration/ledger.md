# ExUnit → Go coverage ledger

Every ExUnit test of Kogen main `76109e1a` (270 tests in 49 files; the earlier sections began at `bdfd607`), with the Go test or installed scenario that now covers its assertions. No row is pending: a script compares this ledger with the test names in `git archive 76109e1a test/` and with the Go test functions in `cli/`, and finds every test mapped and every cited Go test present. The ExUnit tests themselves are deleted; the rows are the record of what covers them. Obsolete harness assertions say so in their row (see `coverage.md`).

| ExUnit file | Test | Go test |
|---|---|---|
| test/acceptance/fixtures/projects/ex-app/test/ex_app_test.exs | double | n/a — a fixture project's own test, not a Kogen test: it still lives at `test/acceptance/fixtures/projects/ex-app/test/ex_app_test.exs` and runs with `mix test` in that folder (the acceptance suite's world builds the `ex-app` fixture project with it; checked: 1 test passes) |
| test/integration/build_boundaries_test.exs | REV-5 reviewer repairs are verified and committed without returning to the builder | TestAReviewerRepairIsVerifiedAndCommittedWithoutReturningToTheBuilder |
| test/integration/build_boundaries_test.exs | REV-5 final verification failures return to the same reviewer context | TestFinalVerificationFailuresReturnToTheSameReviewerContext (the reset inside a review conversation: TestTheReviewAndItsResetsCarryOnlyTheFrozenCallerDiagnostic, TestAReopenedReviewersResetsPreserveTheUnresolvedBlockerAndCannotAuthorizeACommit) |
| test/integration/build_boundaries_test.exs | preflight missing packages and malformed approval remain structured read observations | TestPreflightMissingPackage, TestPreflightStaleAndMalformedApproval, TestPreflightObservesWithoutRunningGitHooksOrWriting, TestPreflightReadyTextAndJSON, TestReadOnlyObservationLeavesTheRepositoryAlone (git part: no fsmonitor hook, no index write) |
| test/integration/build_boundaries_test.exs | resuming pending reviewer verification keeps repairs with the reviewer | TestAResumeInAReviewStageContinuesWithTheReviewer (Build side: the review stage is checkpointed and handed to the reviewer; the reviewer conversation itself is pending), TestALegacyReviewCheckpointContinuesTheSameReviewerConversation, TestALegacyReviewVerifyCheckpointJudgesTheSavedVerdictWithoutAskingAgain, TestAnInterruptedVerificationOfAReviewerRepairResumesWithoutANewRequest, TestAnInterruptedReviewResumesInTheSameReviewerConversation (the Build side: TestAResumeInAReviewStageContinuesWithTheReviewer in this ledger) |
| test/integration/build_boundaries_test.exs | blocked #{retry_outcome} retry provider failure retains fresh evidence and the saved reviewer | TestALegacyRetryCheckpointSendsTheBlockerAndTheFreshResultsToTheSameReviewer, TestABlockedRetryThatFailsAtTheContinuedRequestKeepsFreshEvidenceAndTheSavedReviewer (subtests green, setup red) |
| test/integration/build_boundaries_test.exs | pre-clean checkpoints cannot authorize resume | TestResumeRefusals (version 1, 2, 3, 999, text), TestLegacyResumeRefusals (version 2) |
| test/integration/build_boundaries_test.exs | clean #{stage} input mutations cannot certify the workspace | TestChecksThatChangeTheCandidateCannotCertifyAPass |
| test/integration/build_boundaries_test.exs | clean setup failure returns command output without a partial green pass | TestCleanVerificationOfTheCandidateFeedsBackWhatChanged, TestFailedSetupRetainsEvidenceAndNamesLaterSetupAndGatesWithoutAnAbsentModel (verify part) |
| test/integration/build_boundaries_test.exs | workspace drift during clean checks cannot certify a pass | TestChecksThatChangeTheCandidateCannotCertifyAPass, TestChangesWhileTheChecksRanMakeThePassNotGreen (verify part) |
| test/integration/build_boundaries_test.exs | resume refuses damaged index custody, configuration and required saved state before effects | TestResumeRefusals (damaged index backup, index custody, configuration, missing phase and every other custody case), TestLegacyResumeRefusals (every custody case and every unsafe state, on Elixir-written Builds, with custody, run files, runs and requests unchanged) |
| test/integration/build_boundaries_test.exs | a core death during resumed commit reports the created commit and cannot commit again | TestResumeRefusals (uncertain commit boundary, head moved); the shell-level crash report belongs to the removed two-process design, TestLegacyResumeRefusals (commit boundary), TestALegacyLandedBuildIsANoOpThatNamesTheCommit |
| test/integration/build_boundaries_test.exs | REV-6 reviewer shell edits cannot change the approved baseline | TestReviewerToolsAreProtectedLikeTheBuilders |
| test/integration/build_boundaries_test.exs | REV-5 interrupted targeted repair reports pending review and changed verification | TestAnInterruptedTargetedRepairReportsPendingReviewAndChangedVerification |
| test/integration/build_boundaries_test.exs | REV-5 unresolved substantive findings stop rather than start another builder round | TestABlockedReviewStopsAndAnExplicitResumeReopensItUnderTheSameReviewer |
| test/integration/build_boundaries_test.exs | reopened reviewer resets preserve the unresolved blocker and cannot authorize commit | TestAReopenedReviewersResetsPreserveTheUnresolvedBlockerAndCannotAuthorizeACommit |
| test/integration/build_boundaries_test.exs | REV-2 review retains full source without replaying new files twice | TestTheReviewerReadsTheFullSourceAndNewFilesAppearOnce, TestTheMaterialEqualsTheElixirReference |
| test/integration/build_boundaries_test.exs | GIT-8 restores the saved index when startup #{stage} fails | TestStartupStagesThatFailRestoreTheIndex, TestIndexCustodyRestoresWhatTheUserStaged (git part: save/restore custody) |
| test/integration/build_boundaries_test.exs | GIT-8/CLI-7 restores the saved index and reports an interrupted startup | TestAnInterruptedStartupRestoresTheIndexAndCannotResume, TestIndexCustodyRestoresWhatTheUserStaged, TestInterruptDuringCommitWaitsForGitAndUndoesALandedCommit (git part) |
| test/integration/build_boundaries_test.exs | CLI-7 undoes a commit interrupted during postcommit validation | TestACommitInterruptedDuringPostcommitIsUndone, TestInterruptDuringPostCommitValidationUndoesTheCommit (git part) |
| test/integration/build_boundaries_test.exs | VER-10/GIT-4 excludes new siblings in another uncommitted Intent folder | TestOtherIntentsStayOutOfTheCandidateAndTheCommit, TestTreeIsBuiltInAPrivateIndexAndExcludesOtherIntents (git part), TestExcludedIntentFoldersAndWorkspaceArtifactsStayOutOfTheCandidate (verify part) |
| test/integration/build_boundaries_test.exs | AUT-2 stops a preflight hook that changes the approved baseline | TestAHookThatChangesTheApprovedBaselineStopsTheBuild, TestCommitMsgHookThatStagesIsUndoneByIndexRestore/exit=0 (git part: the hook's staging and its undo) |
| test/integration/build_boundaries_test.exs | GIT-8 restores the original index when a staging preflight hook rejects | TestCommitMsgHookThatStagesIsUndoneByIndexRestore/exit=12 |
| test/integration/build_boundaries_test.exs | GIT-1 rejects a staged rename from outside the allowed Intent paths | TestChangedPathsStagedRenameIntoAnIntentFolderReportsBothPaths (git part) |
| test/integration/build_boundaries_test.exs | CLI-9 records a successful large Unicode startup check and continues | TestALargeUnicodeStartupCheckIsRecordedCutAndTheBuildContinues (`cli/build/commit_test.go`; the cap itself: TestTheRunLogCapPreservesUTF8AndFitsInOneMiB) |
| test/integration/build_context_files_test.exs | nonregular FIFO and unreadable file fail before provider or custody effects | TestDiagnosticDataThatIsNotValidRefusesBeforeAnyEffect (the file reading is the command line's) |
| test/integration/build_context_files_test.exs | cancelled initial request freezes conversation across source replacement and deletion (context=#{diagnostic?}) | TestBuildWithDiagnosticDataKeepsItPrivatelyAndSendsItAfterTheOpeningMessage, TestAnInterruptedBuildResumesAndLandsOnceInTheSameConversation, TestALegacyBuilderCheckpointResumesTheSameConversationAndLandsOnce (the resumed request is the saved conversation, item for item; the Elixir run's checkpoint.json and result.json stay byte-identical) |
| test/integration/build_context_files_test.exs | fresh independent review and its resets retain only frozen caller diagnostics, not builder reasoning | TestTheReviewAndItsResetsCarryOnlyTheFrozenCallerDiagnostic |
| test/integration/builder_blocker_test.exs | LOOP-7 a builder-reported protected contradiction stops before later calls or gates | TestABuilderReportedProtectedContradictionStopsBeforeLaterCallsOrGates |
| test/integration/builder_blocker_test.exs | LOOP-7 malformed, empty and unprotected blocker reports return feedback and grant no writes | TestMalformedEmptyAndUnprotectedBlockerReportsGrantNoWrites |
| test/integration/builder_blocker_test.exs | LOOP-7 accepting a blocker still requires the original HEAD and protected bytes | TestAcceptingABlockerStillRequiresTheOriginalHeadAndProtectedBytes |
| test/integration/clean_snapshot_test.exs | declared Git commands see the exact clean inputs without workspace artifacts | TestMaterializeGivesDeclaredCommandsTheExactCleanInputs, TestDeclaredGitCommandsSeeTheExactCleanInputsInAPass (verify part; the rest is this ledger) |
| test/integration/clean_snapshot_test.exs | gitlink inputs retain their exact commit and clean tracked contents | TestMaterializedGitlinksKeepTheirExactCommit, this ledger (TestMaterializedGitlinksKeepTheirExactCommit); no verify-level behaviour of its own |
| test/integration/contract_regressions_test.exs | SHP-10 probe progress reports status without echoing tool output | `shape` (the probe's scratch copy and evidence; `Tools.Probe` is its hook) |
| test/integration/contract_regressions_test.exs | SHP-2 quoted executable paths and assignment values pass tool lookup without execution | TestQuotedExecutablePathsAndAssignmentValuesPassToolLookupWithoutExecution |
| test/integration/contract_regressions_test.exs | SET-4 init rejects ignored legacy configuration before login or writes | TestInitRefusesAnEarlierKogensConfigurationBeforeLoginOrWrites |
| test/integration/contract_regressions_test.exs | SHP-4 invalid question options receive correction feedback and are never persisted | TestShapeInvalidQuestionOptionsGetCorrectionFeedbackAndAreNeverPersisted (`cli/shape/contract_test.go`) |
| test/integration/contract_regressions_test.exs | SHP-4 blocked submissions require an actual protected path and a reason | TestShapeBlockedSubmissionsNeedAnActualProtectedPathAndAReason (`cli/shape/contract_test.go`) |
| test/integration/contract_regressions_test.exs | SHP-4 blocked reports recognize protected paths matched by a glob | TestShapeBlockedReportRecognizesProtectedPathsMatchedByAGlob (`cli/shape/contract_test.go`) |
| test/integration/contract_regressions_test.exs | REL-3 self-build gate runs the maintained suite and propagates its failure | TestSelfBuildGateRunsTheMaintainedSuiteAndPropagatesItsFailure (`cli/release_test.go`: the gate of `test/live/self-build-check.sh` runs the real `test/suite.sh` with a missing archive) |
| test/integration/contract_regressions_test.exs | REL-3 observation rejects an installed release whose core is unavailable | TestObservationRejectsAnInstalledReleaseWithoutItsProgram (`cli/release_test.go`; there is no separate core any more, so the guarantee is that an installed release whose one program is missing or cannot run is never reported as observing the change) |
| test/integration/contract_regressions_test.exs | REL-3 disposable self repositories leave source HEAD, index and edits untouched | TestDisposableSelfRepositoriesLeaveSourceHeadIndexAndEditsUntouched (`cli/release_test.go`) |
| test/integration/fail_fast_verification_test.exs | failed setup retains evidence and names later setup and gates without an absent model | TestCleanVerificationOfTheCandidateFeedsBackWhatChanged, TestRedVerificationIsFedBackToTheSameBuilderAndRepaired (the passes themselves: this ledger), TestFailedSetupRetainsEvidenceAndNamesLaterSetupAndGatesWithoutAnAbsentModel |
| test/integration/fail_fast_verification_test.exs | real declared Cucumber fail-fast keeps failed and skipped cases red, while complete exit-zero is green | TestRealDeclaredCucumberFailFastKeepsFailedAndSkippedCasesRedWhileCompleteExitZeroIsGreen |
| test/integration/git_test.exs | a staged rename reports both changed paths, including spaces | TestChangedPathsStagedRenameWithSpaces |
| test/integration/git_test.exs | a detected copy does not also report its source as a rename deletion | TestChangedPathsCopyKeepsSourceOutOfRenames |
| test/integration/local_facts_test.exs | start publishes coherent custody and repeated replacements never tear | TestStartPublishesCoherentCustodyAndRepeatedReplacementsNeverTear (`cli/build/facts_test.go`) |
| test/integration/local_facts_test.exs | damaged catalog cannot abort custody publication; inherited evidence keeps original locations | TestADamagedCatalogCannotAbortCustodyPublicationAndInheritedEvidenceKeepsOriginalLocations (`cli/build/facts_test.go`) |
| test/integration/lock_test.exs | AUT-4/GPT-6 concurrent stale recovery preserves the live owner (#{format}) | TestTheBuildLockIsHeldAndRefusesASecondBuild (the lock itself: this ledger), TestConcurrentStaleRecoveryPreservesTheLiveOwner (subtests pid_file, directory), TestConcurrentStaleRecoveryPreservesTheLiveOwner |
| test/integration/lock_test.exs | release cannot remove a later acquisition, including a repeated release | TestReleaseCannotRemoveALaterAcquisition (its repeated release has no effect) |
| test/integration/provider_diagnostics_test.exs | GPT-8 unknown structured stream failure retains safe fields in refinement evidence | TestUnknownStructuredStreamFailureRetainsSafeFields, TestRefineProviderFailureDiagnosticsReachTheResultWithoutSecrets |
| test/integration/provider_diagnostics_test.exs | GPT-8 HTTP failure metadata reaches Build result and log without request payload | TestHTTPFailureMetadataWithoutPayload |
| test/integration/provider_diagnostics_test.exs | GPT-8 known structured transients keep three attempts and final diagnostics | TestKnownStructuredTransientsKeepThreeAttempts |
| test/integration/provider_diagnostics_test.exs | GPT-8 no-code and malformed stream error fields remain safe diagnostic fallbacks | TestNoCodeAndMalformedStreamErrorFieldsAreSafe |
| test/integration/provider_diagnostics_test.exs | GPT-8 context and login wrappers preserve known response metadata without changing exits | TestContextFailurePreservesMetadataWithoutChangingTheError, TestSecond401IsRejectedWithDiagnostics |
| test/integration/provider_diagnostics_test.exs | GPT-8 a flat error event retains code and event kind without inventing an error subtype | TestFlatErrorEventRetainsCodeAndKind |
| test/integration/provider_diagnostics_test.exs | GPT-8 incomplete stream diagnostics do not present an internal marker as provider code | TestIncompleteStreamHasNoInternalCode |
| test/integration/provider_wait_test.exs | observed cache refusal preserves requests and evidence (single=#{single}, param=#{inspect(param)}) | superseded by the Intent go-core-migration prompt-caching contract: ChatGPT sends a routing key, not retired explicit cache options, so the refusal retry is removed; the surviving property (a cache-field refusal is one plain refusal, nothing replayed) is TestChatGPTRetiredOptionsRefusalsNeverStripTheRoutingKey; SuperGrok keeps its bounded retry: TestSuperGrokCacheKeyRefusalRetriesOnceAndIsRemembered |
| test/integration/provider_wait_test.exs | cache refusal retries once, persists unsupported, and retains real request identifiers | superseded (ChatGPT has no breakpoints to refuse): TestChatGPTRetiredOptionsRefusalsNeverStripTheRoutingKey, TestOtherSuperGrokRefusalsNeverStripTheKey |
| test/integration/provider_wait_test.exs | unrelated refusal never strips cache fields or reexecutes | TestUnrelatedRefusalNeverStripsOrReexecutes |
| test/integration/provider_wait_test.exs | a cache field alone does not authorize compatibility replay | superseded (no ChatGPT compatibility replay exists): TestChatGPTRetiredOptionsRefusalsNeverStripTheRoutingKey, TestOtherSuperGrokRefusalsNeverStripTheKey |
| test/integration/provider_wait_test.exs | inconsistent completed usage is retained but not added to compatible totals | TestInconsistentUsageIsRetainedButNotTotalled |
| test/integration/provider_wait_test.exs | malformed optional write counts never leak into analytical usage | TestMalformedWriteCountsNeverLeak |
| test/integration/provider_wait_test.exs | terminal evidence retains sticky guards but describes only effective replacement items | TestTerminalEvidenceRetainsStickyGuards |
| test/integration/provider_wait_test.exs | terminal evidence distinguishes effective pending and gap predicates | TestTerminalEvidencePendingAndGap |
| test/integration/provider_wait_test.exs | empty terminal metadata retains ordered multiitem output and usage on an open socket | TestEmptyTerminalMetadataKeepsOrderedItemsOnAnOpenSocket |
| test/integration/provider_wait_test.exs | empty final output retains refusal predicates and effective diagnostic facts | TestEmptyFinalOutputRetainsRefusalPredicates |
| test/integration/provider_wait_test.exs | failure events win over retained done items and empty completion | TestFailureEventsWinOverRetainedItems |
| test/integration/provider_wait_test.exs | an expired invocation does not consume the next invocation's budget | TestExpiredInvocationDoesNotConsumeTheNextBudget |
| test/integration/provider_wait_test.exs | the second backoff also spends the original budget | TestSecondBackoffSpendsTheOriginalBudget |
| test/integration/provider_wait_test.exs | single attempt does not retry unreadable output or transient failures | TestSingleAttemptDoesNotRetry |
| test/integration/provider_wait_test.exs | completed output is validated, ordered and failures win | TestCompletedOutputIsValidatedOrderedAndFailuresWin |
| test/integration/provider_wait_test.exs | a validated open stream is cancelled before the caller exits | TestValidatedOpenStreamIsCancelled |
| test/integration/provider_wait_test.exs | expiry is checked with a continuously nonempty mailbox and closes the request | TestExpiryIsCheckedWithBusyStreamAndClosesTheRequest |
| test/integration/provider_wait_test.exs | unreadable output retries once within the same invocation | TestUnreadableOutputRetriesOnce |
| test/integration/readiness_observations_test.exs | SHP-4 narrow shaping corrections retain the model and step files already submitted | TestShapeNarrowCorrectionsRetainTheModelAndStepFilesAlreadySubmitted (`cli/shape/contract_test.go`; runs the real Quint, skipped when `spec/node_modules` is not installed) |
| test/integration/readiness_observations_test.exs | SHP-4 lint corrections keep earlier artifacts and malformed mixed payloads contribute nothing | TestShapeLintCorrectionsKeepEarlierArtifactsAndMalformedMixedPayloadsContributeNothing (`cli/shape/contract_test.go`) |
| test/integration/readiness_observations_test.exs | SHP-4 an earlier step cannot be silently abandoned outside the approval baseline | TestShapeAnEarlierStepCannotBeSilentlyAbandonedOutsideTheApprovalBaseline (`cli/shape/contract_test.go`) |
| test/integration/readiness_observations_test.exs | SHP-4 formatting cannot abandon a retained executable step outside the baseline | TestShapeFormattingCannotAbandonARetainedExecutableStepOutsideTheBaseline (`cli/shape/contract_test.go`) |
| test/integration/readiness_observations_test.exs | SHP-8 declared checks cannot qualify replacement bytes inside their disposable probe | TestDeclaredChecksCannotQualifyReplacementBytesInsideTheirDisposableProbe (verify part) |
| test/integration/readiness_observations_test.exs | SHP-8 feasibility feedback is bounded across obligations while full failures remain inspectable | TestFeasibilityFeedbackIsBoundedAcrossObligationsWhileFullFailuresRemainInspectable (verify part) |
| test/integration/readiness_observations_test.exs | SHP-8 the final shaper sees a fixture failure and repairs it before ready | TestReadinessRefusals (undefined steps, missing and invalid reports, setup, runner exit) (verify part) |
| test/integration/readiness_observations_test.exs | SHP-8 legitimate red is acknowledged unchanged without another check and cards retain observations | TestApproveCardOutput, TestApproveRepeatedCardsReuseReadinessWithoutExecution, TestReadinessAcceptsLegitimateRedAndRetainsObservations (verify part) |
| test/integration/readiness_observations_test.exs | SHP-8 hook locations and explicit UTF-8 truncation reach the same conversation and card | TestRealHookLocationsAndExplicitUTF8TruncationReachTheObservations (verify part) |
| test/integration/readiness_observations_test.exs | SHP-8 changed HEAD cannot acknowledge observations from an earlier check | TestReadinessAcceptsLegitimateRedAndRetainsObservations, TestReadinessRecordEqualsTheElixirRecordAndReadsBack (verify part: Cached and Current refuse a changed HEAD) |
| test/integration/readiness_observations_test.exs | SHP-11 cumulative red proposals stay unpublished until their exact observations are acknowledged | TestRefineCumulativeRedProposalsStayUnpublishedUntilTheirObservationsAreAcknowledged |
| test/integration/readiness_observations_test.exs | SHP-11 unchanged red from initial context acknowledges its existing check | TestRefineUnchangedRedFromTheInitialContextAcknowledgesItsExistingCheck |
| test/integration/readiness_observations_test.exs | native Shape returns missing and oversized source comparisons for correction before readiness | TestShapeReturnsMissingAndOversizedSourceComparisonsForCorrectionBeforeReadiness (`cli/shape/contract_test.go`) |
| test/integration/refinement_test.exs | SHP-11 a narrow retry preserves all earlier well-formed proposals until merged readiness | TestRefineNarrowRetryPreservesAllEarlierProposalsUntilMergedReadiness |
| test/integration/refinement_test.exs | SHP-11 a mixed unsafe payload contributes no proposals to a later narrow retry | TestRefineAMixedUnsafePayloadContributesNoProposals |
| test/integration/refinement_test.exs | SHP-11 later proposals replace a path and explicit original bytes revert it | TestRefineLaterProposalsReplaceAPathAndOriginalBytesRevertIt |
| test/integration/refinement_test.exs | SHP-11 a delta changes one draft file, preserves other bytes and still needs approval | TestRefineWritesTheCorrectionAndPrintsTheLines, TestRefineOriginalReadinessHitRetainsTheRecordWithoutExecution (the `broken record` loop over `intent approve` cards belongs to `verify.Readiness.Cached` and `Approve`, see this ledger and this ledger) |
| test/integration/refinement_test.exs | SHP-11 invalid, unsupported, provider and not-ready results preserve the ready draft | TestRefineInvalidUnsupportedProviderAndNotReadyResultsPreserveTheReadyDraft (subtests invalid, unsupported, provider, not ready, topology) |
| test/integration/refinement_test.exs | SHP-11 rejects protected and shared step edits without changing the original package | TestRefineRejectsProtectedAndSharedStepEditsWithoutChangingThePackage, TestRefineProtectedPathsAreNotEditable |
| test/integration/refinement_test.exs | SHP-11 an approved correction archives the exact approval and requires a fresh approval | TestRefineAnApprovedCorrectionArchivesTheExactApprovalAndNeedsAFreshOne |
| test/integration/refinement_test.exs | SHP-11 stale hashes, approval mismatches and dirty implementation refuse before model requests | TestRefineStaleHashesApprovalMismatchesAndDirtyImplementationRefuseBeforeModelRequests |
| test/integration/refinement_test.exs | SHP-11 failed and cancelled approved corrections preserve package, raw approval and index | TestApproveBuildRunning, TestRefineFailedAndCancelledApprovedCorrectionsPreservePackageRawApprovalAndIndex (including approval refused with `environment/build_running` while the refinement runs) |
| test/integration/refinement_test.exs | SHP-11 failed approval revocation restores a read-only artifact and retains approval | TestRefineFailedApprovalRevocationRestoresAReadOnlyArtifactAndRetainsApproval |
| test/integration/refinement_test.exs | SHP-11 changes to HEAD, raw approval or index prevent approved publication | TestRefineChangesToHeadRawApprovalOrIndexPreventApprovedPublication |
| test/integration/refinement_test.exs | SHP-11 an external edit while refining is preserved and prevents publication | TestRefineAnExternalEditWhileRefiningIsPreservedAndPreventsPublication |
| test/integration/refinement_test.exs | SHP-11 interruption during a probe preserves the ready package and retained evidence | TestRefineInterruptionDuringAProbePreservesThePackageAndRetainsEvidence |
| test/integration/refinement_test.exs | a runner failure after passing scenarios never supplies reusable readiness | TestApproveRunnerFailureAfterPassingScenariosNeverSuppliesReadiness, not here: `verify` and `approve` (see this ledger), TestRunnerFailureAfterPassingScenariosNeverSuppliesReusableReadiness (verify part) |
| test/integration/refinement_test.exs | readiness mutations cannot certify the changed baseline, even on repeated cards | TestApproveReadinessMutationsCannotCertifyTheCandidate, not here: `verify` and `approve` (see this ledger), TestReadinessMutationsCannotCertifyTheChangedBaselineEvenOnRepeatedChecks (verify part) |
| test/integration/refinement_test.exs | approval publication drift restores exact prior approval without certifying changed inputs | TestApproveReadinessInputsChangeDuringApproval (with and without a prior approval), not here: `approve` (see this ledger) |
| test/integration/refinement_test.exs | SHP-11 local ignored warmth stays available to probes but out of final proof | TestRefineLocalIgnoredWarmthStaysAvailableToProbesButOutOfFinalProof (`info/exclude` and `core.excludesFile`; the final-proof half is also `verify`'s TestLocallyIgnoredWarmthIsAvailableToProbesButOutOfFinalProof), TestLocallyIgnoredWarmthIsAvailableToProbesButOutOfFinalProof (verify part) |
| test/integration/refinement_test.exs | Refine refuses changed or deleted bound source during inference without publishing or revoking approval | TestRefineRefusesChangedOrDeletedBoundSourceDuringInferenceWithoutPublishingOrRevoking |
| test/integration/refinement_test.exs | exact approval refuses source drift during readiness instead of silently rebinding it | TestApproveSourceProvenanceChangedDuringReadiness, not here: `approve` (see this ledger) |
| test/integration/release_behavior_test.exs | SET-10/VER-3 both generated runners preserve feature and report paths with spaces | TestRealBothGeneratedRunnersPreserveFeatureAndReportPathsWithSpaces (verify part) |
| test/integration/release_behavior_test.exs | REV-4/REV-5 retries one invalid review verdict and lands after approval | TestTheReviewHookRunsAfterAGreenPassAndItsApprovalIsCommitted, TestBuildLandsOneCommitWithTheIntentTrailer (Build side), TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild (retried once, the verdict rules, a reply without a verdict twice), TestTheReviewerApprovesUnchangedCodeWithoutRepairs |
| test/integration/release_behavior_test.exs | GIT-5/GIT-8 a rejecting commit hook leaves edits and restores the staged Intent index | TestACommitHookThatRejectsLeavesEditsAndRestoresTheStagedIntentIndex |
| test/integration/release_behavior_test.exs | GIT-6/GIT-8 an editing hook is undone and the original staged Intent index is restored | TestAHookThatEditsTheCommitIsUndoneAndTheIndexRestored, TestSigningIsHonoured, TestASigningFailureLeavesTheChangesUncommitted |
| test/integration/release_behavior_test.exs | GIT-8 a provider failure leaves edits and restores the staged Intent index | TestAProviderFailureLeavesEditsAndRestoresTheIndexAndResumes |
| test/integration/release_behavior_test.exs | GIT-8/CLI-7 an interrupt leaves edits and restores the staged Intent index | TestAnInterruptedBuildResumesAndLandsOnceInTheSameConversation |
| test/integration/release_behavior_test.exs | GPT-3/GPT-6 a stale credentials lock is removed before refresh | TestStaleLockOfADeadProcessDoesNotBlockRefresh, TestStaleLocksOfDeadOrCorruptOwnersAreReplaced (kogen/provider) |
| test/integration/release_behavior_test.exs | GPT-3/GPT-6 a live credentials lock makes refresh wait until it is released | TestRefreshWaitsForAHeldLockAndUsesTheNewerToken, TestAcquireHeldByLiveProcessAndObserve (kogen/provider) |
| test/integration/release_behavior_test.exs | CLI-9 UTF-8 output survives the bridge and an invalid byte becomes U+FFFD, UTF-8 locale | TestRunKeepsOutputBytesWhateverTheLocale (kogen/sys), TestEncodeSortsKeysAndEscapesLikeKogenAlwaysHas (kogen/agent: invalid byte encodes as U+FFFD) |
| test/integration/release_behavior_test.exs | CLI-9 UTF-8 output survives the bridge and an invalid byte becomes U+FFFD, no LANG | TestRunKeepsOutputBytesWhateverTheLocale (kogen/sys), TestEncodeSortsKeysAndEscapesLikeKogenAlwaysHas (kogen/agent) |
| test/integration/release_behavior_test.exs | CLI-4 the core starts from a folder holding one-letter file names | not applicable: kogen is one Go program and starts no core process |
| test/integration/review_material_test.exs | small source remains inline without new custody | TestSmallSourceRemainsInlineWithoutNewCustody, TestSmallSourceIsDeliveredInline |
| test/integration/review_material_test.exs | exact UTF8 source delivery survives reset and damaged custody refuses | `build` (uses `read_file` and `Cut` as the Go `Tools` and `Cut` now do: TestCutMatchesTheElixirCut, TestToolsMatchTheElixirResults), TestExactUTF8SourceDeliverySurvivesResetAndDamagedCustodyRefuses, TestSourceIsSplitInOrderWithoutLosingAByteOrBreakingAnEncoding, TestLargeSourceIsDeliveredAsPinnedPartsAndMustBeReadBeforeApproval, TestApprovalNeedsEveryPinnedPartDeliveredInACompletedContinuation |
| test/integration/review_material_test.exs | irreducible authority refuses without files or index changes | TestIrreducibleReviewAuthorityRefusesWithoutFilesOrIndexChanges |
| test/integration/shape_dispatch_test.exs | ownership and boundary refusal precedes calls and never alters raw index | TestBatchOwnershipAndBoundaryRefusalPrecedesCallsAndNeverAltersTheRawIndex |
| test/integration/shape_dispatch_test.exs | draft boundaries reject unsupported artifacts, even with an expectation | TestBatchDraftBoundariesRejectUnsupportedArtifacts |
| test/integration/shape_dispatch_test.exs | an existing editable step is a valid draft target, with current boundaries | TestBatchAnExistingEditableStepIsAValidDraftTarget |
| test/integration/shape_dispatch_test.exs | context is index-first and explicit excerpts retain exact frozen provenance | TestContextIsIndexFirstAndExcerptsRetainExactFrozenProvenance |
| test/integration/shape_dispatch_test.exs | revision notices nonignored untracked drift without real-index writes | TestBatchRevisionNoticesNonignoredUntrackedDriftWithoutRealIndexWrites, TestRevisionFollowsTheCheckoutWithoutTouchingTheRealIndex |
| test/integration/shape_worker_bounds_test.exs | twelve ordinary tools plus two probes are valid; either adjacent excess fails without replay | `shape` (bounds of the shaper's batch; `Tools` has no counters), TestShapeBatchBoundsTwelveToolsAndTwoProbes |
| test/integration/source_provenance_files_test.exs | successful source publication is private, hash bound and preserves immutable predecessors | TestSourcePublicationIsPrivateHashBoundAndPreservesPredecessors (kogen/project) |
| test/integration/source_provenance_files_test.exs | source comparison is copied completely at its UTF-8 byte boundary, never silently clipped | TestSourceComparisonCopiedCompletelyAtByteBoundary (`cli/project/provenance_test.go`) |
| test/integration/supergrok_test.exs | selected roles check only their own providers; saved borrowed login is refused offline | TestRequireLoginChecksOnlyUsedProviders |
| test/integration/supergrok_test.exs | refresh rotates privately, re-reads newer credentials under the lock and defaults expiry | TestSuperGrokRefreshRotatesPrivately |
| test/integration/supergrok_test.exs | refresh failure #{@reason}/#{@code} retains earlier bytes | TestSuperGrokRefreshFailureRetainsEarlierBytes |
| test/integration/supergrok_test.exs | SuperGrok workers refresh once after 401 and preserve routed attempt identity | TestSuperGrokWorkersRefreshOnceAfter401 |
| test/integration/supergrok_test.exs | device lifetime expires while a token poll is still in flight | TestSuperGrokDeviceLifetimeExpiresWhileAPollIsInFlight |
| test/integration/supergrok_test.exs | absent scope and interval use RFC defaults; id token never persists | TestSuperGrokLoginDefaultsAndStorage |
| test/integration/working_context_test.exs | resets retain observations, complete latest exchange and private exact history, not stale green | TestResetsRetainObservationsTheLatestExchangeAndPrivateExactHistoryNotStaleGreen, TestTheLocalResetEqualsTheElixirReference, TestAConversationOverTheBudgetIsResetToALocalWorkingWindow |
| test/integration/working_context_test.exs | irreducible authority refuses without archive or checkout changes | TestIrreducibleAuthorityRefusesWithoutArchiveOrCheckoutChanges |
| test/kogen/build_context_test.exs | bounded original UTF-8 bytes and exact text | TestDiagnosticDataIsBoundedOriginalUTF8 |
| test/kogen/build_context_test.exs | exact shape and digest independently of the source filesystem | TestDiagnosticDataShapeAndDigestAreExact |
| test/kogen/checks_test.exs | VER-4: only generated reports with a finished complete scenario and no extras pass | TestAccountOnlyFinishedCompleteScenariosWithNoExtrasPass (all 480 combinations of steps, reported steps, status, finished and extras) |
| test/kogen/checks_test.exs | SHP-8: binding problems survive failed assertions, unlike ordinary skipped steps | TestAccountBindingProblemsSurviveFailedAssertionsUnlikeSkippedSteps |
| test/kogen/checks_test.exs | VER-4: an expected scenario absent from the report is missing | TestAccountScenarioAbsentFromReportIsMissing |
| test/kogen/checks_test.exs | VER-4: the same scenario key reported twice is duplicate | TestAccountSameScenarioKeyReportedTwiceIsDuplicate |
| test/kogen/checks_test.exs | VER-4: a result for an unexpected feature remains a problem | TestAccountResultForUnexpectedFeatureRemainsAProblem |
| test/kogen/checks_test.exs | VER-4: willBeRetried excludes the failed attempt when the retry passes | TestAccountWillBeRetriedExcludesTheFailedAttemptWhenRetryPasses |
| test/kogen/checks_test.exs | VER-4: truncated reports without a finished case or a result for every step are invalid | TestAccountTruncatedReportsAreInvalid |
| test/kogen/checks_test.exs | VER-4: a garbage line makes the report invalid | TestAccountGarbageLineMakesTheReportInvalid |
| test/kogen/checks_test.exs | VER-4: a missing report is reported once with the command's exit status and output | TestAccountMissingReportIsReportedOnceWithExitStatusAndOutput |
| test/kogen/checks_test.exs | VER-4: a nonzero exit with every scenario passed is still a problem | TestAccountNonzeroExitWithEveryScenarioPassedIsStillAProblem |
| test/kogen/checks_test.exs | VER-3 / VER-4: Scenario Outline results use each Examples row line as the key | TestAccountScenarioOutlineResultsUseEachExamplesRowLineAsTheKey |
| test/kogen/checks_test.exs | VER-5 model feedback keeps the error Quint prints first and the summary it prints last | TestBoundedTextsEqualTheElixirReference (Excerpt cases), TestRealQuintTypecheckFailureIsNamedWithItsStatusAndOutput |
| test/kogen/checks_test.exs | VER-5 short model feedback is kept whole | TestBoundedTextsEqualTheElixirReference (Excerpt cases) |
| test/kogen/config_test.exs | SET-8: generated settings use block collections and preserve long command values | TestRenderConfigBlockCollectionsAndLongValues |
| test/kogen/config_test.exs | SET-8: empty generated settings retain the template's nulls and empty lists | TestRenderEmptyConfigEqualsTemplate |
| test/kogen/config_test.exs | SET-8: commands, checks, acceptance, protect, and model defaults are interpreted | TestParseConfigInterpretsCommands |
| test/kogen/config_test.exs | SET-8: obsolete planner settings do not add a planner role | TestParseConfigIgnoresPlanRole |
| test/kogen/config_test.exs | SET-8: a plain command scalar keeps its comma and shell arguments | TestParseConfigPlainScalarKeepsComma |
| test/kogen/config_test.exs | SET-8: acceptance run and steps_dir may remain null until configured | TestParseConfigAcceptanceNull |
| test/kogen/config_test.exs | SET-4 / SET-8: invalid configuration errors name the file and each source line | TestParseConfigInvalidNamesFileAndLine |
| test/kogen/config_test.exs | SET-4: loading an invalid project file reports its actual path and source line | TestLoadConfigReportsActualPathAndSourceLine |
| test/kogen/config_test.exs | provider selections preserve omission and validate every role and effort | TestProviderSelections |
| test/kogen/detect_test.exs | SET-10: root and cli Go modules get real Go checks without protecting manifests | TestDetectGoModules |
| test/kogen/detect_test.exs | SET-11: one-time machine bootstrap is not recurring project setup | TestInitValidateRefusesOneTimeMachineBootstrap, shape: Init.validate |
| test/kogen/detect_test.exs | SET-11: deduplicate exact commands without assuming test paths are covered | TestInitMergeDeduplicatesExactCommands, shape: Init.merge |
| test/kogen/detect_test.exs | SET-10: a Mix project with a formatter and credo gets setup, fixer, checks and protect | TestDetectMixWithFormatterAndCredo |
| test/kogen/detect_test.exs | SET-10: a Mix project without .formatter.exs or credo gets compile and test only | TestDetectMixWithoutFormatterOrCredo |
| test/kogen/detect_test.exs | SET-10: npm scripts become checks, npm's placeholder test does not, a taken name is prefixed | TestDetectNpmScripts |
| test/kogen/detect_test.exs | SET-10: an existing Cucumber runner and its steps folder are found | TestDetectCucumberRunner |
| test/kogen/detect_test.exs | SET-11: a proposed check replaces the detected one of the same name, others are added after | TestInitMergeProposedCheckReplacesDetectedOthersFollow, shape: Init.merge |
| test/kogen/detect_test.exs | SET-11: dependency-only manifests and lockfiles cannot be protected, but check definitions and settings can | TestInitValidateDependencyOnlyManifestsAreNotEligible, shape: Init.validate |
| test/kogen/detect_test.exs | SET-11: protection validation includes detected checks when the proposal adds none | TestInitValidateProtectionIncludesDetectedChecks, shape: Init.validate |
| test/kogen/detect_test.exs | SET-11: Mix test discovery and coverage settings are verification configuration | TestInitValidateMixTestDiscoveryAndCoverageAreVerificationConfiguration, shape: Init.validate |
| test/kogen/detect_test.exs | SET-11: the committed Mix test-selection settings are protected verification configuration | TestInitValidateCommittedMixTestSelectionIsProtectedConfiguration, shape: Init.validate |
| test/kogen/detect_test.exs | SET-11: invalid names, duplicates, reserved names and untracked protect paths are problems | TestInitValidateNamesDuplicatesReservedAndUntrackedAreProblems, shape: Init.validate |
| test/kogen/feasibility_test.exs | ordinary version-3 records need no feasibility proof | TestOrdinaryVersion3RecordsNeedNoFeasibilityProof |
| test/kogen/feasibility_test.exs | declarations require unique ids and ordered actual observer controls | TestDeclarationsRequireUniqueIDsAndOrderedActualObserverControls |
| test/kogen/feasibility_test.exs | rejection evidence binds command, bytes and complete actual outcome | TestRejectionEvidenceBindsCommandBytesAndCompleteActualOutcome |
| test/kogen/gherkin_test.exs | VER-3 / VER-4 / SHP-5: scenarios expose their report lines, inherited steps, tags, and Then steps | TestGherkinScenariosExposeReportLines |
| test/kogen/gherkin_test.exs | SHP-5: malformed outline structure returns a source-line problem | TestGherkinMalformedOutlineReturnsLineProblem |
| test/kogen/image_test.exs | original bytes stay typed through output, cut, deletion and complete JSON accounting | TestOriginalBytesStayTypedThroughOutputCutDeletionAndCompleteJSONAccounting (typed parts, metadata, `Cut`, call/output pair, provider request body, 524287/524288/524289 byte measure and `GuardImages`) |
| test/kogen/image_test.exs | bounded decoder rejects malformed framing, CRC, unsupported encodings, filters and bombs | TestBoundedDecoderRejectsMalformedFramingCRCUnsupportedEncodingsFiltersAndBombs; every message also compared with Elixir's in TestToolsMatchTheElixirResults |
| test/kogen/image_test.exs | dimension, byte and filter inclusive bounds | TestDimensionByteAndFilterInclusiveBounds |
| test/kogen/image_test.exs | compact events distinguish read, rejection, uncertain transport and completed delivery | TestCompactEventsDistinguishReadRejectionUncertainTransportAndCompletedDelivery (the events are built here; writing them to the run log is `build`'s) |
| test/kogen/intent_test.exs | SHP-5: formatted Acceptance lists read and lint with leading blank lines | TestIntentAcceptanceListsReadAndLintWithLeadingBlankLines |
| test/kogen/intent_test.exs | SHP-5: Acceptance only skips blanks before the first bullet | TestIntentAcceptanceOnlySkipsBlanksBeforeFirstBullet |
| test/kogen/intent_test.exs | AUT-2 / VER-1: changing, adding, removing, or renaming any baseline file changes its hash | TestHashChangesWithAnyBaselineChange |
| test/kogen/intent_test.exs | AUT-2: the approval hash does not depend on baseline listing order | TestHashIgnoresListingOrder |
| test/kogen/intent_test.exs | VER-1: protect paths, folders, and globs select the matching Git files and no neighbors | TestProtectedPathsFoldersAndGlobs |
| test/kogen/prompt_cache_test.exs | stable boundaries retain authority and isolate dynamic bytes | TestStableBoundariesRetainAuthorityAndIsolateDynamicBytes, TestFingerprintsMatchElixirVectors |
| test/kogen/prompt_cache_test.exs | comparison and unsupported state stay in the independent conversation | superseded (no comparison response id on the wire): TestCacheStatesAreSavedPerConversationAndOnlySuperGrokRemembersARefusal, TestDifferentConversationsNeverShareACacheIdentity |
| test/kogen/prompt_cache_test.exs | replay preserves valid supported fields without manufacturing absent legacy values | TestReplayPreservesValidSupportedFieldsWithoutManufacturingAbsentLegacyValues and TestReplayFiltersMessageContentAndFunctionCallFields (`cli/agent`: `agent.Replay`, which Shape's `ReplayItems` uses) |
| test/kogen/prompt_cache_test.exs | optional diagnostics are bounded classified evidence, not text | TestCacheDiagnosticsAreClassifiedEvidence |
| test/kogen/prompt_cache_test.exs | usage validates disjoint writes and subset reasoning without clamping | TestUsageValidatesDisjointWritesAndSubsetReasoning |
| test/kogen/provider_test.exs | Shape includes enabled workers but Refine can select only the Shape role | TestRoleNames; TestShapeCommonHelpers (`ShapeRoles`: the shape role first, plus read/probe/draft only when workers are enabled); TestRefineRefusalsBeforeTheModel/enabled_workers_need_no_login_for_Refine (workers on an unsigned SuperGrok do not stop Refine, which reaches its model; checked against a mutant that checks every Shape role) |
| test/kogen/provider_test.exs | SuperGrok plain policy and cache uncertainty are explicitly provider scoped | TestRespondSuperGrokRequestAndHeaders (SuperGrok now carries prompt_cache_key and no options), TestEveryConversationHasOneCacheIdentityAndAppendOnlyRequests/supergrok |
| test/kogen/run_test.exs | checkpoint decoder refuses damaged, incomplete and incompatible state | TestCheckpointDecoderRefusesDamagedIncompleteAndIncompatibleState, TestLegacyDecodeAcceptsAndRefusesLikeTheElixirDecoder, TestLegacyDecodeRefusesWhatValidStateRefuses, TestLegacyReaderRefusesEverythingElse, FuzzLegacyDecode |
| test/kogen/run_test.exs | green reuse requires complete required clean evidence, not a stored Boolean | TestGreenReuseRequiresCompleteRequiredCleanEvidenceNotAStoredBoolean, TestLegacyDecodeAcceptsAndRefusesLikeTheElixirDecoder (the checkpoint boundary: old and current evidence, cache states, every incomplete pass in `last_pass` and in the continuation), TestLegacyDecodeRefusesIncompleteReviewAndPassState; the pass check itself is `verify.Pass.Complete`, TestCompleteRequiresRequiredCleanEvidenceNotAStoredBoolean, TestPassCompleteEqualsTheElixirVerdictOnEveryReference (verify part; checkpoint decoding is the build package's) |
| test/kogen/run_test.exs | atomic checkpoint publication leaves prior valid document through interrupted publication | TestAtomicCheckpointPublicationLeavesThePriorValidDocument |
| test/kogen/run_test.exs | the run log cap preserves UTF-8 and fits in 1 MiB including its marker | TestTheRunLogCapPreservesUTF8AndFitsInOneMiB, TestCapPreservesUTF8AndFitsInAMebibyteIncludingItsMarker |
| test/kogen/shape_context_test.exs | explicit windows preserve adjacent line and UTF-8 byte bounds | `shape` (`ShapeContext.excerpt`, not a tool; `read_file` line windows are covered below), TestExcerptWindowsPreserveAdjacentLineAndUTF8ByteBounds |
| test/kogen/shape_context_test.exs | explicit windows do not invent a line after the source final newline | `shape` (same), TestExcerptWindowsDoNotInventALineAfterTheSourceFinalNewline |
| test/kogen/shape_speed_test.exs | worker configuration is opt-in, complete, exact and line-numbered | not here: `project` (`ParseConfig`) |
| test/kogen/shape_speed_test.exs | cancellation and overlapping completed calls remain in final timing and usage | TestEvidenceCancellationAndOverlappingCompletedCallsRemainInTimingAndUsage |
| test/kogen/shape_speed_test.exs | main recovery records each completed transport without claiming retry delay as model time | TestEvidenceRecoveryRecordsEachTransportWithoutClaimingRetryDelayAsModelTime (the failure detail is the attempt record's `provider_failure`, as `provider.Observer` delivers it) |
| test/kogen/shape_speed_test.exs | interval unions do not double count overlaps and handle adjacent boundaries | TestEvidenceIntervalUnionsDoNotDoubleCountOverlapsAndHandleAdjacentBoundaries |
| test/kogen/working_context_test.exs | complete rendered request has exact UTF-8 size and adjacent inclusive boundaries | TestMeasureIsTheExactUTF8SizeOfTheCompleteRequestWithInclusiveBoundaries |
| test/kogen/yaml_test.exs | SET-4 / SET-8: block command scalars preserve commas and YAML source lines | TestYAMLBlockScalarsKeepCommasAndLines |
| test/kogen/yaml_test.exs | SET-4: a duplicate YAML key reports the line where it is repeated | TestYAMLDuplicateKeyReportsRepeatLine |

Rows the per-package ledgers recorded for tests that are not listed above:

| ExUnit file | Test | Go test |
|---|---|---|
| test/integration/build_boundaries_test.exs | review card, then exact approval by prefix (build setup, approve part) | TestApproveWithFullAndPrefixHash, TestApproveCardPassesNow |
| test/integration/working_context_test.exs | history custody missing, changed or unsafe (WorkingContext.validate!) | TestLegacyResumeRefusesWorkingContextHistoryCustody |

## Pending

No row is pending.

## Go coverage by package

Coverage notes by behaviour, from the per-package ledgers. Go test names are in the package named in each heading.

### Agent package: ExUnit to Go ledger

Rows for the ExUnit tests whose assertions concern `cli/agent` (`lib/kogen/tools.ex`, `lib/kogen/image.ex`, `Shape.replay_item/decode/output`, the prompt functions). Go test names are in package `kogen/agent` (`cli/agent/*_test.go`).

## Not claimed here

| ExUnit file | Test | Owner |
|---|---|---|

## Behaviour with no ExUnit test of its own

The Elixir suite reaches these only through full Builds, Reviews and Shapes. The Go package compares them with the Elixir functions directly: the golden files in `cli/agent/testdata` are generated by `gen_static.exs` and `gen_tools.exs` from the Elixir source (see their headers for the commands).

| Behaviour | Go test |
|---|---|
| Each prompt (builder, reviewer, shaper, refine, init, shaper context guidance, readiness acknowledgment guidance, feasibility guidance, testing rules) is byte-equal to the Elixir function's text | TestPromptsAreByteEqualToTheElixirFunctions |
| `docs/testing-rules.md` and the embedded copy are byte-equal | TestTheTestingRulesUsersReadAreTheOnesEmbedded |
| Shaper and refine templates hold the shared guidance passages once; `{{name}}` rendering | TestShaperAndRefineShareTheGuidancePassages, TestRender |
| Every tool definition (`Kogen.Tools.defs/1`, `submit`, `submit_review`, `submit_refinement`, `submit_configuration`, `shape_batch`, `worker_result`) equals the Elixir map | TestDefinitionsMatchTheElixirDefinitions, TestDefsKeepTheOrderAskedFor, TestEveryDefinitionIsPlainJSON |
| `read_file`: line numbers, `start_line`/`end_line` windows, empty and final-newline files, folders, missing files, links, `~`, NUL, argument errors | TestToolsMatchTheElixirResults (211 calls), TestNumberedWindows, TestTildeIsTheHomeFolder |
| `write_file`: `ok`, folders created, protected baseline paths refused however spelled, `eisdir`/`enotdir` errors, argument errors | TestToolsMatchTheElixirResults, TestWriteFileCreatesFoldersAndReplacesContent, TestWriteFileRefusesProtectedPathsHoweverTheyAreSpelled, TestFileErrorsUseErlangsReasonNames |
| `list_files` and `search_text`: Git commands, untracked and ignored files, no-match texts, Git errors, path outside the repository | TestToolsMatchTheElixirResults, TestListAndSearchUseTheRepoGiven, TestListAndSearchOutsideARepositoryAreErrors |
| `shell`: `/bin/sh -c` in the root, stdin closed, `exit status: N` plus combined output, no time limit, interrupt is an error | TestShellRunsInTheRootWithStdinClosedAndReportsStatusAndOutput, TestShellUsesTheSessionsEnvironment, TestShellHasNoTimeLimit, TestShellInterruptIsAnErrorNotAResult, TestShellNeedsACommandString, TestShellResultNeedsCutWhenLong |
| Tools not enabled for the role answer `error: unknown tool` | TestToolsRefuseNamesThatAreNotEnabled, TestToolsMatchTheElixirResults |
| `probe` is the shaper's (hook) | TestProbeBelongsToTheShaper |
| `Cut`: 16 KiB limit, first 4 KiB, omitted-bytes marker, whole characters, invalid UTF-8, typed parts unchanged | TestCutMatchesTheElixirCut, TestCutKeepsHeadAndTailAroundAMarker, TestCutEndsOnWholeCharacters, TestCutOfAnOutputPassesTypedPartsUnchanged |
| `view_image`: 52 PNG variants and path/argument errors with Elixir's messages (including `Erlang error: :data_error`), metadata text in Elixir's key order, read candidate tree (or `UNKNOWN`) | TestToolsMatchTheElixirResults, TestViewImageNeedsARegularReadableFile, TestViewImageNamesTheCandidateItWasReadFrom, TestViewImageOutsideARepositoryHasAnUnknownCandidate |
| Image accounting: entries, guard only for requests with images, delivery status, events, bounded text, no events without images | TestImageEntriesNeedExactlyMetadataTextAndImage, TestGuardIgnoresAConversationWithoutImages, TestDeliveryStatus, TestDeliverReportsNothingWithoutImages, TestBoundedTextCutsOnACharacter |
| Replay of messages (supported content parts only) and function calls (supported fields only); calls paired with outputs in order; unanswered calls; typed or text output items | TestReplayFiltersMessageContentAndFunctionCallFields, TestCallsPairWithOutputsInOrder, TestOutputItemCarriesTextOrTypedParts, TestCallsTakeOnlyFunctionCallsAndTolerateMissingFields, TestUnansweredMatchesByCallID |
| Arguments decode to a JSON object or `{"__invalid__": true}`; Erlang's JSON accepts and refuses the same text (surrogates, UTF-8, number range, first of a repeated key) | TestDecodeArgumentsIsAnObjectOrTheInvalidMarker, TestDecodeAcceptsAndRefusesWhatErlangsJSONDoes, TestDecodeKeepsIntegersAndFloatsApart |
| JSON encoding for the context measure: sorted keys, Kogen's escapes, Erlang float form | TestEncodeSortsKeysAndEscapesLikeKogenAlwaysHas, TestFormatFloatIsErlangsShortestForm |
| Path handling: `Path.expand` and `Path.relative_to` equivalents | TestExpandNormalisesWithoutResolvingLinks, TestRelativeTo |

### ExUnit to Go coverage: `kogen/shape` approve and preflight

Go tests are in `cli/shape/approve_test.go` and `cli/shape/preflight_test.go`. They run against temporary repositories (test identity in the repository config, `core.hooksPath` set to an empty temporary folder, no global Git configuration) whose acceptance command is a script that replays prepared Cucumber Messages reports, so the real readiness check (clean scratch directory, accounting, evidence) runs. Rows marked (approve part) are Build-, Shape- or Refine-level ExUnit tests whose `intent approve` / `intent preflight` effects are covered here; their remaining assertions belong to the `build` and `shape` (refine) tests and stay `pending` in `ledger.md`.

Behaviour in `spec/features/03-approval-and-build-start.feature` and `spec/prose/03-approval-and-build-start.md` that has no ExUnit test of its own:

| Clause | Go test |
|---|---|
| AUT-1 card for a failing and a passing Intent; `--by` and `git var GIT_AUTHOR_IDENT` approver | TestApproveCardOutput, TestApproveCardPassesNow, TestApproveWithoutGitIdentityAndBy |
| AUT-1 Scenario Outline appears once with its example count and `fails now` if any row fails | TestApproveCardGroupsOutlineRows |
| AUT-1 `intent/approval_identity_unavailable` (exit 2), `intent/not_found` (exit 2), `intent/questions_pending` (exit 5) | TestApproveWithoutGitIdentityAndBy, TestApproveMissingIntent, TestApproveQuestionsPending |
| AUT-2 hash prefix of 6 to 64 characters; `intent/hash_mismatch` refused before readiness | TestApproveWithFullAndPrefixHash, TestApproveHashMismatch |
| AUT-2 cached readiness skipped for the same baseline, HEAD and candidate tree, else readiness runs again | TestApproveWithFullAndPrefixHash, TestApproveWithoutCachedEvidenceRunsReadiness, TestApproveRepeatedCardsReuseReadinessWithoutExecution |
| AUT-2 approval shares the project lock (`environment/build_running`, lock released afterwards) | TestApproveBuildRunning, TestApproveWithFullAndPrefixHash |
| AUT-2 interrupt during publication restores the previous approval or its absence | TestApproveInterruptDuringPublication |
| source provenance bound into the approval and shown on the card; existing approval with a broken bound receipt; receipt bound to another contract | TestApproveBindsSourceProvenance, TestApproveRefusesBrokenBoundSourceOfExistingApproval, TestApproveSourceReceiptBoundToAnotherContract |
| `environment/not_a_git_repo` outside a repository | TestApproveNotAGitRepository |
| preflight: text and JSON, blockers with paths, dirty tree (at most 20 paths), Build lock and Git operation, unreadable project configuration (exit 3), checkout defaulting | TestPreflightReadyTextAndJSON, TestPreflightBlockedWithoutApproval, TestPreflightDirtyTree, TestPreflightDirtyTreeListsAtMostTwentyPaths, TestPreflightConflicts, TestPreflightProjectConfigurationUnreadable, TestPreflightJSONDefaultsCheckoutFromProject, TestPreflightInvalidPackageJoinsProblems |

### ExUnit to Go coverage: package `kogen/build` (build and resume core)

Go tests are in `cli/build`. The independent review conversation (`review.go`, `material.go`) and the import of version 3 checkpoints (`legacy.go`) belong to a later change: the Build core calls them through `Reviewer` and `LegacyDecoder` (`hooks.go`). Rows that need the real review stay `pending` in `ledger.md`. Reference replays (`testdata/gen/*.exs`, run with `mise exec -- mix run --no-start cli/build/testdata/gen/<script>.exs` in the repository root) pin the builder's opening message and the working-context reset byte for byte.

Behaviour with no ExUnit test of its own, covered in Go: the builder's opening message equals the reference (TestOpeningMessageEqualsTheElixirReference), run records and `result.json` (TestBuildRunRecords), start refusals (TestStartRefusals, TestBuildWithoutLoginIsRefusedBeforeAnyRun, TestACommitMsgHookThatRejectsTheMessageStopsBeforeAnyModelTime), fixers and the failing-check refusal (TestFixersRunOncePerRoundAndChecksFailBeforeAnyChange), context exhaustion (TestContextLengthExhaustionStopsTheBuild), local facts inherited across a resume (TestAResumedRunInheritsTheEvidenceOfThePreviousRun), an uncertain tool boundary (TestResumeRefusesAnUncertainToolBoundary), history custody (TestResumeRefusesWorkingContextHistoryCustody, TestAnArchivedWindowThatChangedIsRefused), the hooks (TestTheReviewHookRunsAfterAGreenPassAndItsApprovalIsCommitted, TestAReviewThatBlocksStopsTheBuildWithoutACommit, TestTheStubReviewerApprovesAndRecordsItself, TestVersion3CheckpointsGoThroughTheImporter).

### ExUnit to Go coverage: package `kogen/git`

Go test names are in `cli/git`. Rows marked (git part) are Build-level ExUnit tests whose Git effects are covered here; their remaining assertions (output text, run records, provider calls) belong to the `build` package and stay `pending` in `ledger.md` until it covers them.

## Behaviour with no ExUnit test of its own

The Elixir suite covers these only through full Builds. The Go package tests them directly.

| Behaviour | Go test |
|---|---|
| Repository root discovery, subdirectory, symlinked spelling | TestRootDiscovery |
| `environment/not_a_git_repo` message and exit 3 | TestOpenOutsideRepositoryIsNotAGitRepo |
| HEAD, empty repository | TestHead |
| Identity and `environment/git_identity_missing` | TestIdentity |
| `show` of a path at a revision | TestShowTrackedAndMissing |
| Operation in progress (merge, rebase, cherry-pick, revert) | TestOperationInProgress |
| Tracked, unignored and ignored listings | TestTrackedUnignoredIgnored |
| NUL-safe changed paths with odd names, pathspec limits | TestChangedPathsNULSafeAndFiltered |
| Revisions that look like options are refused everywhere | TestResolveRefusesOptionLikeRevisions |
| No history rewriting or sharing commands through the runner | TestRunnerRefusesRewritingAndSharingCommands |
| stderr stays out of parsed output; command errors carry it | TestRunnerKeepsStderrOutOfParsedOutput |
| No inherited GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE; explicit variables pass | TestChildrenDoNotInheritRepositoryLocation, TestReadOnlyKeepsExplicitEnvironment |
| Clean snapshot of a clean checkout is HEAD's tree | TestTreeOfACleanCheckoutIsHeadsTree |
| Changed paths and diffs between trees | TestChangedAndDiff |
| Materialize refuses unsafe paths and symlinked folders | TestMaterializeRefusesUnsafeTargets |
| Materialize with odd names, large files, empty tree | TestMaterializeKeepsFilesWithOddNamesAndEmptyTrees |
| Materialize into a relative directory; missing tree | TestMaterializeIntoARelativeDirectoryAndMissingTree |
| Commit message format | TestCommitMessageFormat |
| Commit lands the reviewed tree with the right parent, message, trailer | TestCommitLandsTheReviewedTree |
| User hooks run | TestCommitRunsTheUsersHooks |
| Signing honoured, and not added when the user does not sign | TestCommitHonoursSigning, TestCommitDoesNotSignWhenTheUserDoesNot |
| Commit ignores inherited repository location | TestCommitIgnoresInheritedRepositoryLocation |
| `environment/commit_failed` with Git's output | TestCommitFailureReportsGitOutputAndLeavesTheCommitUndone |
| Read-only repositories cannot commit | TestCommitRefusesAReadOnlyRepository |
| `candidate/hook_changed_commit`: hook changed the tree; undone, reflog entry | TestCommitUndoesACommitWhoseHookChangedTheTree |
| `candidate/hook_changed_commit`: unsigned when the user signs; other parent | TestCommitUndoesACommitThatIsNotSignedWhenTheUserSigns, TestCommitUndoesACommitWithAnotherParent |
| Interrupt waits for `git commit`, undoes a landed commit; nothing starts after an interrupt | TestInterruptDuringCommitWaitsForGitAndUndoesALandedCommit, TestInterruptBeforeCommitStartsEffectsNothing |
| commit-msg hook check and `environment/commit_rejected` tail | TestCheckCommitMsgHook, TestCheckCommitMsgRejectionWithoutOutputHasOneEmptyLine, TestTailLines |
| Configuration commit of exactly some paths, with and without HEAD, failure unstages | TestCommitPathsCommitsOnlyThosePaths, TestCommitPathsInAnEmptyRepository, TestCommitPathsFailureUnstagesAndReportsOutput |
| Index custody errors, atomic restore, `ReadTree` | TestIndexCustodyErrors, TestReadTreeStagesATree |
| Build lock: stale removal notice, live refusal, free lock | TestLocksLeftByAnEarlierKogen (an earlier Kogen's stale lock is removed with the notice), TestAKilledOwnersLockIsTakenWithoutANotice, TestAcquireRefusesALiveLockAndHeldObservesIt, TestAcquireCreatesTheLocalFolderAndTakesAFreeLock |
| Lock observation without recovery; contenders; pid liveness; damaged lock | TestAcquireRefusesALiveLockAndHeldObservesIt, TestLockAcquireContendersNeverBothWin, TestProcessAliveIsKillZero, TestLockOwnerDiagnostics, TestStaleLocksOfDeadOrCorruptOwnersAreReplaced |

### ExUnit → Go coverage ledger: `kogen init` (`cli/shape/init.go`)

The ExUnit tests of `Kogen.Init.validate/2` and `Kogen.Init.merge/2` (the rows of this ledger marked `shape:`) and the integration test that runs `kogen init`, with the Go test in `cli/shape/init_test.go` that covers each.

`TestInitValidateCommittedMixTestSelectionIsProtectedConfiguration` reads `testdata/init/kogen-mix.exs`, a copy of this repository's `mix.exs` (the ExUnit test reads `git show HEAD:mix.exs`).

## Mix verification settings

The Elixir Kogen parses the committed `mix.exs` with `Code.string_to_quoted` to decide whether a manifest defines verification (SET-11). The Go package has no Elixir parser; `init.go` carries a small token scanner (comments, strings, heredocs, sigils, zero-argument `def`/`defp`, literal keyword lists, aliases by name or by function). `testdata/init/mix-golden.json` pins the answer of `Kogen.Init.validate/2` for 282 cases (47 `mix.exs` texts, including this repository's own, times 6 check sets; 94 eligible, 188 not), generated by `testdata/init/gen.exs`; `TestInitMixVerificationMatchesElixir` runs the Go scanner on every case with no difference.

## Scenarios of `spec/features/01-project-setup.feature` exercised in Go (scripted httptest provider, temp repositories, fake `mix`/`npm`/`node`)

| Scenario | Go test |
|---|---|
| Init configures a project without checks or runner, adds the bridge and commits once | TestInitConfiguresAProjectWithoutChecksAndAddsTheBridge |
| Init configures an Elixir project and leaves out a check that fails on the committed tree | TestInitLeavesOutAFailingCheckOnTheCommittedTree, TestInitRunsEveryProjectCommandOnACopyOfTheCommittedTree |
| Init configures a Node project with its existing runner and a check the model found | TestInitUsesTheProjectsOwnCucumberRunner |
| An existing runner that does not start is reported and acceptance stays unset | TestInitReportsAnExistingRunnerThatDoesNotStart, TestInitBridgeThatWritesNoReportIsNotAdded |
| Init asks once to remove dependency-only protection and keeps formatter protection | TestInitAsksOnceToRemoveDependencyOnlyProtection |
| Two invalid configuration replies end init without writing anything | TestInitTwoInvalidAnswersEndWithNothingWritten |
| Init without a login writes nothing | TestInitWithoutLoginWritesNothing |
| In a repository without commits, init makes the first commit | TestInitEmptyRepositoryMakesTheFirstCommit, TestInitEmptyRepositoryKeepsAnExistingGitignore |
| Init outside a Git repository is refused | TestInitNotAGitRepository |
| Init refuses when .gitignore has uncommitted changes | TestInitRefusesUncommittedChangesToTheFilesItWrites |
| A second init changes nothing | TestInitAlreadyInitializedChangesNothing, TestInitAlreadyInitializedPrintsWhatIsMissing |
| Init commits the files that a failed init commit left behind | TestInitCommitsTheConfigurationAFailedInitLeftBehind, TestInitCommitFailureLeavesTheFilesUncommitted |
| An invalid config is reported with line numbers | TestInitLeftoverConfigurationMustBeValid |
| Init without a Git identity writes nothing | TestInitWithoutGitIdentityWritesNothing |
| A configuration from the earlier Kogen is named as such and nothing is written | TestInitRefusesAnEarlierKogensConfigurationBeforeLoginOrWrites |
| Init in a repository whose files are not committed yet asks for the first commit | TestInitRefusesFilesNotCommittedYet |
| Init leaves out a setup command that cannot run twice on the same tree | TestInitLeavesOutSetupThatCannotRunTwiceOnTheSameTree, TestInitSetupThatFailsIsLeftOut |

Scenarios that need the real Cucumber, Node and shaping (the generated bridge shaping and building in a checkout with spaces, Kogen data staying ignored) belong to the acceptance suite, not to this package.

### ExUnit to Go coverage: reading the Elixir Kogen's version 3 checkpoints (`cli/build/legacy.go`)

Go tests are in `cli/build/legacy_test.go`. The fixtures in `cli/build/testdata/legacy/` are written by the real Elixir Kogen: `gen.exs` builds the Build map the way `Kogen.Build.checked/5` does, saves each stage with `Kogen.Build.save/2` and reads every checkpoint back with `Kogen.Run.decode_checkpoint/1` (`mise exec -- mix run --no-start cli/build/testdata/legacy/gen.exs cli/build/testdata/legacy` in the repository root; the output folder is the argument). The project the Builds belong to is `testdata/legacy/project`; its start commit and trees are the same on every run, and the tests rebuild the repository at a new path and move the paths of the saved state (the saved terms re-encode to the very bytes Elixir wrote: `TestTheWriterGivesBackTheBytesTheElixirKogenSaved`). The Elixir reader refuses atoms its VM has not seen; the Go reader reads atoms as text and checks what it uses, so that one `binary_to_term` refusal has no counterpart.

### ExUnit → Go coverage ledger: package `project`

The ExUnit tests of `config`, `yaml`, `gherkin`, `intent` and `detect` and the Go test (in `cli/project`) that covers each. Rows whose Go test says `shape: ...` test `Kogen.Init.validate/2` or `Kogen.Init.merge/2`, which are `kogen init` rules owned by the `shape` package, not by `project`; they are not covered here.

Beyond these rows the package carries Elixir-pinned parity tests: `testdata/golden.json` holds the results of the Elixir Kogen for 116 configuration texts, 6 rendered configurations, 125 YAML texts, 46 feature files, 50 Intent checks, 9 Intent reads and 23 detection inputs (generated by `testdata/golden-gen.exs`), and `testdata/parity.json` pins the baseline file list and approval hash the Elixir Kogen computes for three real Intent packages of this repository (`TestIntentHashMatchesElixir`). The YAML reader, the configuration validator and the Gherkin parser were also compared with the Elixir ones on 12,000 mutated YAML texts (each also read as configuration) and 11,000 mutated feature files, with no difference (one-off run, not kept).

### Provider package: ExUnit to Go ledger

Rows for the ExUnit files whose assertions concern `cli/provider` (`lib/kogen/{chatgpt,supergrok,provider,prompt_cache,usage,lock}.ex`). Go test names are in package `kogen/provider` (`cli/provider/*_test.go`).

## Notes

- Build/refine/shape plumbing named in a few ExUnit titles (Build result and run log persistence, refinement result files, exit codes of Build context exhaustion, Shape evidence rows) is outside this package. Here the same assertions are made on what the package owns: the `*sys.Error` (`Class`, `Reason`, `Detail`, `Lines`, `ProviderFailure`) and the `Observer` attempt records. The callers' tests carry the rest.
- `ShapeEvidence.provider`/`transport` wrapping is the caller's: it implements `Observer`. The attempt record is the `provider` object of the run log's `provider_attempt` event.
- `Kogen.Lock` is `provider.Locker`/`provider.Lock`; its two ExUnit tests ran two OS processes and a `kill` wrapper, the Go tests use two contenders in one process with an injected liveness check.
- Added Go tests with no ExUnit row: Elixir-vector digests (`TestFingerprintsMatchElixirVectors`, `TestEncodeJSONMatchesElixir`), ChatGPT/SuperGrok sign-in (`TestChatGPT*`, `TestSuperGrok*Login*`), refresh and lock behaviour (`auth_test.go`), headers per provider, error classification tables, secrets, interrupts.

### Refine (`kogen intent refine`): ExUnit to Go ledger

Go tests are in `cli/shape/refine_test.go` (package `kogen/shape`). They run against temporary repositories (test identity in the repository config, `core.hooksPath` set to an empty temporary folder, no global Git configuration, a temporary `HOME` with a saved login) whose draft `is-even` is ready, with its readiness recorded and, where the ExUnit test approves, an approval. The provider is a scripted `httptest` server (`helper_test.go`); the acceptance command is a script that replays prepared Cucumber Messages reports, so the real readiness check (clean materialized candidate, accounting, evidence) runs for the original and for every candidate.

Differences of the fixture from the ExUnit fixture: the draft declares `Model: not applicable` (no Quint run); the ExUnit model edits (`invariants =Safety`) are replaced by the equivalent unparseable `Model:` line and an unsourced decision, which the same lint rejects. Interrupts are `Session.Interrupt` with `SIGINT`, `SIGTERM` and `SIGHUP` (exit 130, 143, 129).

## Behaviour of `Kogen.Refine.run/5` (spec/prose/02-shaping.md SHP-11, spec/features/02-shaping.feature) without an ExUnit test of its own

| Clause | Go test |
|---|---|
| Scenario "A targeted correction reuses exact original evidence and still requires approval": stdout lines `refined <slug> <sha8>`, `Changed:`, `Evidence:`, `Next:`; the four tools offered; original readiness receipt `hit`; Build refuses afterwards | TestRefineWritesTheCorrectionAndPrintsTheLines, TestRefineOriginalReadinessHitRetainsTheRecordWithoutExecution |
| Scenario "A narrow lint correction retains earlier proposed artifact edits in the same run" | TestRefineNarrowRetryPreservesAllEarlierProposalsUntilMergedReadiness |
| Scenario "Correcting an approved package revokes approval and requires a fresh exact approval" | TestRefineAnApprovedCorrectionArchivesTheExactApprovalAndNeedsAFreshOne |
| Scenario "An unsupported correction preserves the ready draft" (`shape/refinement_constraint`, exit 1) | TestRefineInvalidUnsupportedProviderAndNotReadyResultsPreserveTheReadyDraft (unsupported) |
| Original readiness on a miss: check in scratch, `original-readiness.json` status `miss`, one acceptance execution | TestRefineOriginalReadinessMissChecksTheOriginalInScratch |
| Red candidate: observations return in the same conversation, an exact unchanged acknowledgment reuses them, a changed candidate is checked again, observations do not count as invalid | TestRefineRedCandidateReturnsObservationsAndAChangedOneIsCheckedAgain, TestRefineAChangedCandidateAfterRedGetsFreshChecks, TestRefineRedOriginalGivesTheModelItsObservationsAndAcknowledgmentReusesThem |
| Three invalid or not-ready submissions end with `shape/refinement_invalid`; an answer without a call is asked for `submit_refinement`; envelope problems (empty files, path without content, blank constraint) | TestRefineInvalidSubmitIsRetriedAndAnAnswerWithoutCallsIsAsked, TestRefineThreeInvalidSubmissionsStopIt, TestRefineBlankConstraintIsInvalid |
| Read-only answers do not count as invalid submissions; only one submission counts per response | TestRefineAReadOnlyAnswerDoesNotCountAsInvalid, TestRefineOnlyOneSubmissionCountsPerResponse |
| Probes run in a copy of the scratch checkout with the accumulated proposal applied, outside the project | TestRefineProbeRunsInTheScratchCopyWithTheProposalApplied |
| Fixers format the submitted files; a failing fixer or one changing other files is unsupported work | TestRefineFixersFormatTheCandidateAndCannotTouchOtherFiles |
| Source provenance: the receipt is bound, shown to the model, appended with the correction and the prior contract hash, its comparison and contract hash replaced, the old receipt archived; an unbound receipt refuses before the model | TestRefineRecordsTheCorrectionInTheSourceReceipt, TestRefineSourceReceiptThatIsNotBoundIsRefusedBeforeTheModel |
| Preconditions in order: `intent/not_found`, `environment/acceptance_unconfigured`, `intent/not_ready`, pending shaping questions, `intent/refinement_hash` (exit 2), `environment/no_head`, login, `environment/build_running`, `environment/not_a_git_repo` | TestRefineRefusalsBeforeTheModel |
| Context cancelled before the run stops without writing the draft | TestRefineStopsWhenTheContextIsCancelled |
| Evidence: `request.md` 0600 in a 0700 folder, `original/`, `publish/`, `rollback/`, `candidate-N/`, `submission-N.json`, `diagnostic-N.txt`, `result.json` (`ready`, `failed` with `error` and `provider_failure`, `interrupted` with `signal`), `events.ndjson` with provider call, context selection, probes and session end; scratch checkout and Build lock removed | TestRefineWritesTheCorrectionAndPrintsTheLines, TestRefineInterruptionDuringAProbePreservesThePackageAndRetainsEvidence, TestRefineInvalidUnsupportedProviderAndNotReadyResultsPreserveTheReadyDraft |

Faithful quirk kept: a constraint raised while a submission is checked (a failing fixer, a fixer changing other files, an Acceptance or model topology change, readiness changing candidate files) reaches the user with the sentence ` The original draft is preserved.` twice, as the Elixir Refine prints it (`TestRefineFixersFormatTheCandidateAndCannotTouchOtherFiles`, topology subtest of `TestRefineInvalidUnsupportedProviderAndNotReadyResultsPreserveTheReadyDraft`).

### ExUnit to Go coverage: the independent review (`cli/build/review.go`, `cli/build/material.go`)

Go tests are in package `kogen/build` (`review_test.go`, `material_test.go`) and run the real reviewer (`Deps.Reviewer` nil) against a scripted `httptest` provider in temporary repositories. The core tests of the package keep the stand-in reviewer (`approveWithoutReview`, set by the `deps()` helper of `helper_test.go`).

Reference replay: `testdata/gen/review.exs` (run with `mise exec -- mix run --no-start cli/build/testdata/gen/review.exs` in the repository root) runs the Elixir `Review.material/2` and `ReviewMaterial.prepare/7` on a fixed repository and writes `testdata/review/material-golden.json`; `TestTheMaterialEqualsTheElixirReference` compares the authority, the source, the check results, the catalog of files, the opening message of a pinned-parts review, every part's SHA-256 and the first and last part's bytes.

## Intents of `.kogen/intents` without an ExUnit test of their own

| Intent | Clause | Go test |
|---|---|---|
| reopen-blocked-review | explicit resume replaces terminal changes replay with fresh verification and same-reviewer explicit clearance | TestABlockedReviewStopsAndAnExplicitResumeReopensItUnderTheSameReviewer |
| reopen-blocked-review | complete fresh verification is required and stale green/approval cannot override unresolved, fresh-red or setup-failed blockers | TestAReopenedReviewSeesFreshRedResultsAndStaleApprovalCannotClearIt, TestABlockedRetryThatFailsAtTheContinuedRequestKeepsFreshEvidenceAndTheSavedReviewer |
| reopen-blocked-review | verification and continued reviewer interruptions retain owner, guards and safe resumability without terminal replay | TestAnInterruptedVerificationOfAReviewerRepairResumesWithoutANewRequest, TestAnInterruptedReviewResumesInTheSameReviewerConversation |
| reopen-blocked-review | custody, immutable failed artifacts, lineage, original finding/conversation and cumulative known usage survive retry/repeated attempts | TestABlockedReviewStopsAndAnExplicitResumeReopensItUnderTheSameReviewer (original checkpoint unchanged, `resumed_from`, `root_build`, three attempts in `review-1.json`), TestABlockedRetryThatFailsAtTheContinuedRequestKeepsFreshEvidenceAndTheSavedReviewer |
| reviewer-style-discipline | the emitted instructions carry the delegation and unchanged-approval paragraphs | TestTheReviewerApprovesUnchangedCodeWithoutRepairs (the instructions are `agent.Prompt(agent.Reviewer)`, byte-equal to the Elixir text in this ledger) |
| reviewer-style-discipline | unchanged correct-code approval lands with no reviewer edits | TestTheReviewerApprovesUnchangedCodeWithoutRepairs |
| native-image-evidence | the reviewer has its own view_image read and delivery events | TestTheReviewerHasItsOwnImageAccess |
| build-continuity | the review stage resumes from its own checkpoint, inside the same reviewer conversation | TestAnInterruptedReviewResumesInTheSameReviewerConversation |

## Behaviour pinned beyond the ExUnit tests

| Behaviour | Go test |
|---|---|
| A reviewer repair's tree is not the green pass's tree: it is verified, and the review record binds the committed tree | TestAReviewerRepairIsVerifiedAndCommittedWithoutReturningToTheBuilder |
| A reply without `submit_review` is invalid; a second invalid verdict ends the Build with `candidate/review_invalid` and no `review-<n>.json` | TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild |
| Each verdict rule of REV-4 (finding shape, repository path, blocker counts, pinned parts read) names its problem to the reviewer | TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild (problems sent back) |
| A read and an approval in one response deliver nothing; the unread parts are counted and named | TestApprovalNeedsEveryPinnedPartDeliveredInACompletedContinuation |
| A part of the source is split on a UTF-8 boundary within the byte and JSON-size limits | TestSourceIsSplitInOrderWithoutLosingAByteOrBreakingAnEncoding |
| `write_file` refuses a protected path for the reviewer | TestReviewerToolsAreProtectedLikeTheBuilders |

### Shape package (`intent shape`): ExUnit to Go ledger

Go tests are in package `kogen/shape` (`cli/shape/shape_test.go`, `batch_test.go`, `context_test.go`, `evidence_test.go`). The scripted provider is an `httptest` server (`helper_test.go`); the acceptance runner replays prepared Cucumber Messages reports.

## Behaviour of `Kogen.Shape.run/4` (spec/features/02-shaping.feature, SHP-1 to SHP-10)

| Feature scenario | Go test |
|---|---|
| A complete request from stdin becomes a ready Intent and nothing is approved (stdout lines, progress, request contents, tools, no approval, HEAD unchanged) | TestShapeOneShotWritesThePackageAndPrintsTheLines, TestShapeGreenReadinessNeedsNoAcknowledgment |
| Shaping evidence and usage records (`events.ndjson`, usage totals, phases, session end) | TestShapeWritesEvidenceAndUsageRecords |
| Source receipt: request, path, comparison, origin, resolved answers | TestShapeSourceReceiptRecordsRequestAndRounds, TestShapeAnswersContinueShapingAndTheDecisionRecordsItsSource |
| Shaping refuses what it cannot shape (not initialized, acceptance unconfigured, no login, already shaped, failing setup, runner that does not start, not a repository) | TestShapeRefusesWhatItCannotShape |
| An untracked request file is called out; empty checks warn | TestShapeCallsOutAnUntrackedRequestFileAndWarnsAboutEmptyChecks |
| Shaping formats the files it writes with the project's fixers and leaves other files alone | TestShapeFormatsItsFilesWithTheFixersAndLeavesOthersAlone |
| Shaping may edit an existing step file | TestShapeStepFileStates |
| A usage limit stops shaping and writes nothing; provider error names the request file | TestShapeProviderFailureWritesNoFilesAndExplainsTheRerun |
| Interrupt | TestShapeInterruptEndsWithTheSignalAndKeepsEvidence, TestShapeBatchInterruptCancelsEveryJob |
| An open UI/UX choice becomes a numbered question and nothing is written | TestShapeQuestionsPathPrintsNumberedQuestionsAndWritesNothing |
| Answers continue shaping and the decision records its source | TestShapeAnswersContinueShapingAndTheDecisionRecordsItsSource |
| All recommended answers continue shaping | TestShapeAllRecommendedAnswersEveryQuestion, TestShapeAllRecommendedNeedsARecommendedOptionForEveryQuestion |
| Pending questions reject input the caller cannot use; missing answers are asked again without a request | TestShapePendingQuestionsRejectInputeTheCallerCannotUse |
| Three invalid submissions in a row stop shaping and write nothing | TestShapeThreeInvalidSubmissionsStopShapingAndWriteNothing, TestShapeSubmissionEnvelopeProblems, TestShapeWithoutSubmitIsAskedToEndWithSubmit |
| A narrow shaping correction retains earlier proposals | TestShapeInvalidSubmitIsRetriedWithFeedbackAndKeepsEarlierProposals |
| A required protected edit is reported without creating an Intent or approval | TestShapeBlockedReportIsPrintedAndWritesNothing, TestShapeBlockedPathsMayBeConfiguredGlobs |
| Declared proposed steps must stay declared | TestShapeRejectsAnAbandonedDeclaredStep |
| The final shaper repairs observed failure then acknowledges legitimate red; changed candidates get fresh checks | TestShapeRedReadinessReturnsObservationsAndAcknowledgmentReusesThem, TestShapeAChangedPackageAfterRedGetsFreshChecks |
| An undefined step goes back to the shaper and stays not ready | TestShapeUndefinedStepGoesBackToTheShaperAndStaysNotReady |
| After a not-ready attempt the shaper may ask a question; the files stay | TestShapeAfterANotReadyAttemptTheShaperMayAskQuestions |
| A feasibility probe runs in a scratch copy and its result is recorded | TestShapeProbeRunsOutsideTheProjectAndItsResultIsRecorded, TestShapeProbeFailuresAreFindingsNotErrors |
| Read-only tools, no write/shell, no `shape_batch` without workers | TestShapeReadOnlyToolsAnswerAsTheModelExpects |
| `view_image` pixels, `image_read` and `image_delivery` events | TestShapeViewImageDeliversPixelsAndRecordsReadAndDelivery |
| Shape workers: batch, partial, failures, refusals, one batch per conversation | TestShapeBatchRunsWorkersAndReturnsTheirResults, TestShapeBatchPartialWhenOneJobFails, TestShapeBatchWorkerFailuresAreResultsNotErrors, TestShapeBatchRefusalsAndOneBatchPerConversation, TestBatchBriefMustBeCompleteAndProtectEverythingProtected |

Not covered here: the five-minute probe timeout (`verify.Probe`), the `shape-declared-rejection` feasibility evidence flow (`verify`), and `refine`.

### ExUnit to Go coverage: package `kogen/verify`

Go tests are in `cli/verify`. Rows marked (verify part) are Build-, Shape- or Run-level ExUnit tests whose verification effects are covered here; their remaining assertions (checkpoint decoding, provider conversation, output text of other commands) belong to the `build` and `shape` packages and stay `pending` in `ledger.md` until those cover them.

Every test that compares with the Elixir implementation replays fixed inputs through the reference code in `cli/verify/testdata/gen/*.exs` (run with `mise exec -- mix run --no-start <script>` in the repository root) and compares by JSON value against `cli/verify/testdata/golden/*.json`.

## Behaviour with no ExUnit test of its own

The Elixir suite covers these only through full Builds. The Go package tests them directly.

| Behaviour | Go test |
|---|---|
| Accounting of 60 reference reports (every status, hooks with and without location, outlines, rules, retries, absolute feature paths, unknown AST nodes, invalid and missing reports) equals `Kogen.Checks.account/5` | TestAccountEqualsTheElixirAccountingOnEveryReference |
| `Cut`, `Excerpt`, `Tail`, `Cap` and the word splitting of configured commands equal `Kogen.Tools.cut/1`, `Checks.excerpt/1`, `Checks.tail/2`, `Run.cap/1`, `OptionParser.split/1` | TestBoundedTextsEqualTheElixirReference, TestCutKeepsHeadAndTailAtUTF8BoundariesAndNamesTheOmittedBytes |
| Feedback to the repair owner equals `Kogen.Build.pass_feedback/3` | TestPassFeedbackEqualsTheElixirFeedback |
| Completeness verdicts equal `Kogen.Run.complete_pass?/4` | TestPassCompleteEqualsTheElixirVerdictOnEveryReference |
| The pass record has exactly the fields Kogen records, reads back, and keeps legacy records legacy | TestPassRecordHasExactlyTheFieldsKogenRecords, TestPassValidIsTheShapeAResumedRecordMustHave, TestPassRecordsThatCannotBeReadAreRejected |
| Progress summary, notices, checks line and review results lines | TestPassSummaryProgressLine, TestPassChecksLineAndResults |
| Feasibility declarations (46 inputs) and `valid?` (32 proofs) equal `Kogen.Feasibility` | TestDeclarationsEqualTheElixirReadingOnEveryReference, TestValidEqualsTheElixirVerdictOnEveryReference |
| Observations and acknowledgment equal `Kogen.Readiness.observations/3`, `acknowledgment/3` | TestObservationsAndAcknowledgmentEqualTheElixirTexts |
| The version 3 readiness record equals the one `Kogen.Readiness.record_pass!/4` writes (same HEAD, tree and baseline hash), and the Elixir record is reusable | TestReadinessRecordEqualsTheElixirRecordAndReadsBack |
| Verification pass: order, fixers once in the checkout, scratch folder cleanup, environment and acceptance paths, fail-fast with `not_run`, baseline guard after each fixer and the pass, interrupt | TestGreenPassRunsEveryItemInOrderOnTheCleanCandidate, TestFirstRedItemStopsTheLaterOnesAndNamesThem, TestFixersRunOnceInTheCheckoutBeforeThePass, TestBaselineGuardRunsAfterEachFixerAndAfterThePass, TestInterruptStopsThePassAndRemovesTheScratchFolder, TestCommandsGetTheCallersEnvironmentTheToolsAndTheAcceptancePaths, TestAFixerThatExitsNonzeroDoesNotStopThePass, TestACancelledContextStopsBeforeAnyCommandAndLeavesNothingBehind |
| Real Cucumber and real Quint in one pass (typecheck, test, one run per invariant, violation text) | TestRealCucumberAndQuintPassGreenThenModelRedStopsTheChecks |
| Readiness: clean check, evidence reuse, refusals, stale evidence, interrupt, model with Quint, declared evidence with proof | TestReadinessChecksTheCleanCandidateAndKeepsCompleteEvidence, TestReadinessRefusals, TestReadinessCachedMissesAreNormal, TestReadinessRecordIsRefusedWhenItsInputsChangedDuringChecking, TestReadinessInterruptStopsAndCleansUp, TestRealReadinessChecksTheModelWithQuintAndRecordsItsOutcome, TestReadinessRunsDeclaredEvidenceAndRecordsItsProof |
| Setup stamp reuse and failure | TestSetupRunsInOrderAndWarmPreparationReusesItsStamp, TestSetupFailureStopsAtTheFirstFailedCommandWithItsLastLines |
| Tool lookup, runner check, install tool resolution | TestMissingProgramsAreNamedAsToolMissingWithExit3, TestToolLookupResolvesKogenNodeFromTheCallersEnvironment, TestUnclosedQuoteInAConfiguredCommandIsAnInternalFailure, TestRunnerCheckAcceptsARunnerThatExitsZeroAndWritesAReport, TestRequireRunnerRefusesAnUnavailableRunner, TestToolsFromInstallResolveNodeAndTheBundledTools |
| Probes: scratch copy, overlay files, input changes, tools environment | TestExecuteRunsDeclaredChecksInAProbeCopyAndRetainsTheActualOutcome, TestCopyTreeKeepsIgnoredFilesAndLeavesOutGitAndLocalState, TestRunProbeReportsStatusOutputWallAndInputChanges, TestProbeFilesStayInTheScratchCopyAndThePrepareStep |
| test/kogen/open_code_go_test.exs | lossless ordered raw replay suppresses duplicate text and all normalized calls | TestOpenCodeGoRawReplayIsLosslessAndOrdered |
| test/kogen/open_code_go_test.exs | a malformed later call, refusal, truncation or explicit error returns no executable items | TestOpenCodeGoMalformedAnswersReturnNoExecutableItems |
| test/kogen/open_code_go_test.exs | complete selected adapter bytes are inclusive, and images fail before transport | TestRequestBoundaryIsMeasuredOnTheCompleteBodyOfEachAdapter/opencode-go, TestOpenCodeGoRefusesImagesBeforeAnyRequest |
| test/kogen/open_code_go_test.exs | routing separates provider, model, contract, tools, owner and window while retaining append-only identity | TestDifferentConversationsNeverShareACacheIdentity, TestEveryConversationHasOneCacheIdentityAndAppendOnlyRequests/opencode-go (replaced by the Intent's per-conversation identity: contract, tools and window no longer split a conversation) |
| test/integration/open_code_go_login_test.exs | own input trims whitespace without requiring a vendor prefix; invalid and interrupted input preserve exact old bytes | TestKeyLoginTrimsStoresPrivatelyAndPreservesBytesOnRejectedInput/opencode-go, TestKeyLoginInterruptedInputKeepsTheOldKey/opencode-go, TestKeyStatusAndRequiredLogin |
| test/integration/open_code_go_login_test.exs | failed atomic replacement leaves existing bytes and cleans temporary files | TestKeyLoginSaveFailuresPreserveBytesAndCleanUp/opencode-go |
| test/integration/open_code_go_login_test.exs | installed opencode-go piped login rejects invalid UTF-8 instead of saving a replacement key | TestKeyLoginTrimsStoresPrivatelyAndPreservesBytesOnRejectedInput/opencode-go (invalid UTF-8 case) |
| test/integration/open_code_go_login_test.exs | installed opencode-go terminal input never echoes and restores state on success, error and each signal | TestKeyLoginTerminalEchoIsOffWhileTypingAndRestoredOnEveryPath/opencode-go (scripted stty; the real pty journey is the installed suite opencode-go-subscription) |
| test/integration/open_code_go_transport_test.exs | a redirect cannot carry Go authentication to the paid route | TestOpenCodeGoRedirectCannotCarryTheKeyToThePaidRoute |
| test/kogen/anthropic_test.exs | ordered native replay retains opaque blocks once and groups parallel results | TestAnthropicReplayRetainsOpaqueBlocksOnceAndGroupsParallelResults |
| test/kogen/anthropic_test.exs | fragments and cumulative usage merge without adding snapshots | TestAnthropicFragmentsAndCumulativeUsageMergeWithoutAddingSnapshots |
| test/kogen/anthropic_test.exs | complete validation precedes exposing any call | TestAnthropicCompleteValidationPrecedesExposingAnyCall |
| test/kogen/anthropic_test.exs | partial and malformed counts remain unknown, never fabricated zeros | TestAnthropicPartialAndMalformedCountsRemainUnknown |
| test/kogen/anthropic_test.exs | complete rendered bytes keep exact inclusive boundary and typed images refuse | TestRequestBoundaryIsMeasuredOnTheCompleteBodyOfEachAdapter/anthropic, TestAnthropicRefusesImagesBeforeAnyRequest |
| test/integration/anthropic_test.exs | private login preserves bytes on invalid input, interruption, cancellation and contention | TestKeyLoginTrimsStoresPrivatelyAndPreservesBytesOnRejectedInput/anthropic, TestKeyLoginInterruptedInputKeepsTheOldKey/anthropic, TestKeyLoginSaveFailuresPreserveBytesAndCleanUp/anthropic, TestKeyStatusAndRequiredLogin |
| test/integration/anthropic_test.exs | native errors and opaque identifiers cannot echo credentials and waits close the socket | TestAnthropicErrorsAreClassifiedByStatusWithoutEchoingText, TestAnthropicOpaqueIdentifiersCannotEchoTheKeyAndWaitsEndTheRequest, TestKeyProviderInterruptEndsTheRequest |
| test/integration/anthropic_test.exs | installed anthropic piped login rejects invalid UTF-8 / terminal input never echoes (shared with open_code_go_login_test.exs) | TestKeyLoginTrimsStoresPrivatelyAndPreservesBytesOnRejectedInput/anthropic, TestKeyLoginTerminalEchoIsOffWhileTypingAndRestoredOnEveryPath/anthropic |
| test/kogen/config_test.exs | provider selections validate anthropic and opencode-go roles and workers (models and shape_workers) | TestProviderSelections (cli/project/config_test.go), TestConfigMatchesElixir (regenerated golden with eight new cases) |
| test/integration/provider_wait_test.exs | overload retries the complete request and discards failed output | TestRecognizedStreamFailureCodesRetryOnBothRoutesAndEnvelopes, TestOverloadRecoversOnTheThirdAttemptAndExhaustsAfterThree |
| test/integration/supergrok_test.exs | exact codeless generation errors require empty code and subtype on SuperGrok | TestCodelessSuperGrokGenerationFailureRetriesOnlyUnderTheNarrowRule |
| test/integration/supergrok_test.exs | HTTP #{status} #{JSON.encode!(error)} does not permit changing cache requests | TestOtherSuperGrokRefusalsNeverStripTheKey |
| (Intent go-core-migration, prompt caching; no ExUnit file) | one cache identity per conversation; ChatGPT prompt_cache_key (no private-backend session header), SuperGrok prompt_cache_key, OpenCode Go x-opencode-session, Anthropic cache_control; append-only requests, frozen front, deterministic bytes, raw cache fields in usage | TestEveryConversationHasOneCacheIdentityAndAppendOnlyRequests, TestCacheIdentitySurvivesResumeFromCheckpointStates, TestRetriesKeepTheConversationsIdentity, TestAnthropicBreakpointPositionsAndCount, TestRequestBytesAreDeterministic, TestUsageRecordsKeepEachProvidersRawCacheFields, TestChatGPTSendsStatelessCachedRequestsOnEveryModel |
| test/kogen/documentation_test.exs | a pinned base separates search from fetch and keeps honest failures | TestAPinnedBaseSeparatesSearchFromFetchAndKeepsHonestFailures (`cli/agent/documentation_test.go`; the user-agent is `kogen/<second word of the version line>`, not the Mix application version) |
| test/kogen/documentation_test.exs | a 200 search with no fixture sources stays retrieved | TestA200SearchWithNoFixtureSourcesStaysRetrieved |
| test/kogen/documentation_test.exs | connection refusal on the pinned origin is unreachable | TestConnectionRefusalOnThePinnedOriginIsUnreachable |
| test/kogen/documentation_test.exs | a fetch url outside the pinned origin is unsupported and not requested | TestAFetchURLOutsideThePinnedOriginIsUnsupportedAndNotRequested |
| test/kogen/documentation_test.exs | a base-prefixed url whose host is carried in userinfo is not requested | TestABasePrefixedURLWhoseHostIsCarriedInUserinfoIsNotRequested |
| test/kogen/documentation_test.exs | a redirect off the pinned origin is not followed | TestARedirectOffThePinnedOriginIsNotFollowed |
| test/kogen/documentation_test.exs | a same-origin redirect does not forward userinfo | TestASameOriginRedirectDoesNotForwardUserinfo |
| test/kogen/documentation_test.exs | an invalid UTF-8 body that contains the untrusted marker stays untrusted | TestAnInvalidUTF8BodyThatContainsTheUntrustedMarkerStaysUntrusted |
| test/kogen/documentation_test.exs | a large untrusted body stays classified and fits the tool output | TestALargeUntrustedBodyStaysClassifiedAndFitsTheToolOutput |
| test/kogen/documentation_test.exs | an unknown operation and a non-http url are unsupported | TestAnUnknownOperationAndANonHTTPURLAreUnsupported |
| test/kogen/documentation_test.exs | public search copies only decoded anchors inside b_algo results | TestPublicSearchCopiesOnlyDecodedAnchorsInsideBAlgoResults, TestPublicSearchUsesTheConfiguredSearchPage (agent) |
| test/kogen/documentation_test.exs | a documentation lookup is retained without the document body | TestADocumentationLookupIsRetainedWithoutTheDocumentBody (`cli/shape/discovery_test.go`: records, events, progress lines, modes; also the discovery-policy sentence TestTheShaperAndRefinePoliciesStateTheDiscoveryRulesAndTheRecordingSentence) |
| test/kogen/shape_context_test.exs | navigation has fixed shape across empty, small and large candidate trees | TestNavigationHasFixedShapeAcrossEmptySmallAndLargeCandidateTrees (`cli/shape/context_test.go`) |
| test/kogen/feasibility_test.exs | observer polarity cannot be waived by matching successful or rejected controls | TestObserverPolarityCannotBeWaivedByMatchingSuccessfulOrRejectedControls (`cli/verify/feasibility_test.go`) |
| test/kogen/stages_test.exs | absent plan is unchanged; explicit plan retains ordered literals | TestAnAbsentPlanIsUnchangedAndAnExplicitPlanRetainsOrderedLiterals (`cli/project/stages_test.go`; `Stages.initial/1` is the Build's state, covered by its own tests) |
| test/kogen/stages_test.exs | all specified schema errors name stages rather than silently ignoring metadata | TestEverySpecifiedSchemaErrorNamesStages, TestAMalformedPlanIsAnIntentLintProblem (`cli/project/stages_test.go`; the Intent check reports the problem as Elixir's `Intent.check` does) |
| test/kogen/stages_test.exs | stage navigation cannot claim builder work under another saved owner | not here: `Stages.valid?/1` is Build state validation (`cli/build`) |
| test/integration/shape_working_context_test.exs | repeated windows archive exact input and previous handoff, keeping full newest batch | TestRepeatedWindowsArchiveExactInputAndPreviousHandoffKeepingFullNewestBatch (`cli/shape/window_test.go`) |
| test/integration/shape_working_context_test.exs | reset event measures the actual new-window cache envelope | TestTheResetEventMeasuresTheRequestOfTheNewWindow (the event's `after_bytes` is the measured byte count of the request the provider package renders for the new window; there is no ChatGPT `prompt_cache_options` envelope any more, by the caching Intent) |
| test/integration/shape_working_context_test.exs | unsafe ancestor custody refuses before writing an unsent archive | TestUnsafeAncestorCustodyRefusesBeforeWritingAnUnsentArchive |
| test/integration/shape_working_context_test.exs | #{damage} custody refuses even an otherwise fitting next request | TestDamagedCustodyRefusesAnOtherwiseFittingNextRequest (changed, missing, symlink, mode), TestADamagedDocumentationSnapshotIsDamagedCustody |
| test/integration/shape_working_context_test.exs | irreducible authority is retained exactly unsent | TestIrreducibleAuthorityIsRetainedExactlyUnsent, TestARefineWindowLivesInTheRunEvidenceAndNamesItsOwner (the refine owner) |
| test/integration/shape_context_publication_test.exs | snapshot damaged by a completed tool refuses the next tool in the same batch | TestASnapshotDamagedByACompletedToolRefusesTheNextToolInTheSameBatch (`cli/shape/custody_test.go`) |
| test/integration/shape_context_publication_test.exs | custody damaged during final readiness cannot publish successful evidence | TestCustodyDamagedDuringFinalReadinessCannotPublishSuccessfulEvidence |
| test/integration/shape_worker_bounds_test.exs | workers receive bounded long-line reads and replay the delivered display exactly | TestWorkersReceiveBoundedLongLineReadsAndReplayTheDeliveredDisplayExactly (`cli/shape/batch_test.go`) |
| test/integration/source_provenance_files_test.exs | historical contract refresh retains exact originals and predecessor custody | TestHistoricalContractRefreshRetainsExactOriginalsAndPredecessorCustody, TestRefreshSourceRefusesAReceiptThatIsNotTheOneRead (`cli/project/provenance_test.go`) |
| test/integration/source_provenance_files_test.exs | (binding/2 without the contract hash; used by the existing tests) | TestBindSourceRefusesAnythingButAnIntactVersionOneReceipt, TestBindSourceRefusesAProvenanceFolderWithoutAReceipt, TestResolveApprovalPinsAStaleMarkersReceiptByItsDigest |
| test/integration/refinement_test.exs | SHP-11 stale hashes and approved-current dirty implementation refuse before model requests | TestRefineStaleHashesApprovalMismatchesAndDirtyImplementationRefuseBeforeModelRequests (renamed: kinds hash and dirty; a marker for another contract no longer refuses by itself) |
| test/integration/refinement_test.exs | SHP-11 unrelated stale legacy approval does not impose Build-clean restrictions | TestRefineAnUnrelatedStaleLegacyApprovalDoesNotImposeBuildCleanRestrictions |
| test/integration/refinement_test.exs | SHP-11 failed and cancelled approved corrections preserve package, raw approval and index | TestRefineFailedAndCancelledApprovedCorrectionsPreservePackageRawApprovalAndIndex (now with a bound receipt that must stay byte for byte), TestRefineRollsBackItsReceiptWhenTheCheckoutChangesDuringPublication, TestRefineOfAHistoricalContractResolvesTheStaleMarkersReceiptAndKeepsThePredecessor, TestRefineRefusesAMarkerWhoseReceiptPointerIsNotThePinnedCurrentOne |
| test/integration/refinement_test.exs | approval publication drift restores exact prior approval without certifying changed inputs | TestApprovePublicationDriftRestoresThePriorApprovalAndTheOriginalReceiptWithItsArchive (the drift is the `approveAfterWrite` test hook instead of a git wrapper script), TestApproveReadinessInputsChangeDuringApproval |
| test/integration/refinement_test.exs | approval rollback preserves external receipt and marker edits during publication | TestApproveRollbackPreservesExternalReceiptAndMarkerEditsDuringPublication, TestApproveInterruptDuringPublication |
| test/integration/refinement_test.exs | (Approve: stale approval retained, historical receipt named on the card, staged plan card, full hashes; Intents approval-card-recovery, staged-intent-builds) | TestApproveRetainsAStaleApprovalAndNamesItOnTheCard, TestApproveSourceReceiptBoundToAnotherContract, TestApproveRefusesAnUnsafeApprovalHistory, TestApproveCardPrintsTheStagedPlanOfTheIntent, TestApproveCardOutput, TestApproveHashMismatch |
| test/integration/readiness_observations_test.exs | (the scripted `submit` now follows a `read_file`: shape/uninspected, shape/undocumented, shape/hint-not-discovery, shape/untrusted-docs, question kinds; Intents shaping-technical-discovery, documentation-lookup-evidence) | TestShapeRefusesToPublishBeforeAnythingWasInspected, TestShapeQuestionsDoNotNeedInspection, TestShapeKeepsAHandoffQuestionAndRejectsEngineeringQuestions, TestShapeKeepsAQuestionKindFromTheSubmissionLevel, TestShapeRecordsEachDocumentationLookupAsProgressEventAndRecordWithoutTheBody, TestShapeRejectsDocumentationProvenanceThatWasNotRetrieved, TestShapeDoesNotLetAnUntrustedDocumentDirectTheDecisions, TestDocumentationProblemsJudgeEveryRecordedLine (`cli/shape/discovery_test.go`) |
| test/kogen/stages_test.exs | absent plan is unchanged; explicit plan retains ordered literals | TestAnAbsentPlanIsUnchangedAndAnExplicitPlanRetainsOrderedLiterals, TestAnUnstagedBuildKeepsNoStageState (`cli/build/stages_plan_test.go`, `cli/build/stages_test.go`) |
| test/kogen/stages_test.exs | stage navigation cannot claim builder work under another saved owner | TestStageProgressOwnerClaimsAreCheckedAgainstTheSavedContinuation, TestMain76StagedBoundariesAreRefused (genuine main 76109e1a checkpoints; a tool boundary a model request saved has no valid staged phase) |
| test/kogen/stages_test.exs | all specified schema errors name stages rather than silently ignoring metadata | TestEverySpecifiedPlanSchemaErrorNamesStages (`cli/build/stages_plan_test.go`) |
| test/integration/stages_test.exs | stage scratch mutations are red, ordered red stops commands, fresh setup and milestone custody survive Resume | TestStageScratchMutationsAreRedOrderedRedStopsCommandsAndMilestoneCustodySurvivesResume, TestMain76BuildsResumeAndLand/staged_builder_second (a Build the Elixir Kogen saved at its second stage lands once under Go), TestMain76StagedResumeRefusesInconsistentProgressAndEvidence (the same corruptions, and altered, removed, re-moded or unprivate evidence files) |
| test/integration/stages_test.exs | Resume refuses phase claims inconsistent with final work, reviewer ownership or landing | TestResumeRefusesPhaseClaimsInconsistentWithFinalWorkReviewerOwnershipOrLanding, TestMain76StagedLandedBuildIsANoOp, TestMain76BuildsResumeAndLand (staged_builder_final, staged_review_final) |
| test/integration/stages_test.exs | interrupting a stage gate retains no completed evidence and Resume reruns fresh setup and commands | TestInterruptingAStageGateRetainsNoCompletedEvidenceAndResumeRerunsSetupAndCommands, TestMain76BuildsResumeAndLand/staged_builder_second_verify |
| test/kogen/tool_output_test.exs | shared delivery preserves fitting text and bounds oversized text honestly | TestSharedDeliveryPreservesFittingTextAndBoundsOversizedTextHonestly (`cli/agent/cut_output_test.go`; the Build cuts every text it delivers, including the feedback that answers a finish call: TestTheBuilderAndEachReviewHaveTheirOwnSavedCacheIdentity runs through the same path) |
| test/kogen/tool_output_test.exs | a numbered single-line custody read is bounded only at delivery | TestANumberedSingleLineCustodyReadIsBoundedOnlyAtDelivery (`cli/agent/cut_output_test.go`) |
| test/integration/recovery_test.exs | raw filtered bytes, binary, executable modes, symlink targets and deleted paths are archived without index or ignored-output changes | TestRecoveryArchivesRawFilteredBinaryModeSymlinkAndDeletedPathsWithoutIndexOrIgnoredChanges (`cli/build/recover_test.go`), TestMain76RecoveryIdentityOfABlockerIsRecorded (the raw identity the Elixir Kogen recorded equals the one Go computes) |
| test/integration/recovery_test.exs | file-directory replacements preserve both leaf sets and clean only the delta | TestRecoveryOfFileDirectoryReplacementsPreservesBothLeafSetsAndCleansOnlyTheDelta |
| test/integration/recovery_test.exs | publication precedes a controlled local cleanup write failure; candidate rollback and preserved receipt remain honest | TestRecoveryPublicationPrecedesACleanupWriteFailureAndTheReceiptStaysPreserved (skipped for a caller that bypasses directory modes); every named custody refusal: TestRecoveryRefusals, TestRecoveryRefusesABuildThatReportedNoBlocker, TestARecoveredBlockerCannotBeResumedAndRecoversOnlyOnce |
| test/kogen/run_test.exs | checkpoint decoder refuses damaged, incomplete and incompatible state (usage counts may be nil; negative, text, fractional or missing counts are refused) | TestCheckpointUsageCountsMayBeNilButNeverMalformed, TestMain76NullableUsageIsKept, TestUnknownUsageStaysUnknownInTotals, TestAnAnthropicResponseKeepsUnreportedCountsUnknown |
| test/integration/review_material_test.exs | small source remains inline without new custody | TestSmallSourceRemainsInlineWithoutNewCustody (the fitting source is remembered with its tree and material), TestMain76ReviewerKeepsItsInlineSourceAndTree |
| test/integration/review_material_test.exs | fitted inline source relocates on pressure (historical=false / historical=true) | TestFittedInlineSourceRelocatesOnPressure (both subtests) |
| test/integration/review_material_test.exs | #{provider} exact UTF8 source delivery survives reset and damaged custody refuses | TestExactUTF8SourceDeliverySurvivesResetAndDamagedCustodyRefuses (chatgpt and opencode-go) |
| test/integration/working_context_test.exs | #{provider} resets retain observations, complete latest exchange and private exact history, not stale green | TestResetsRetainObservationsTheLatestExchangeAndPrivateExactHistoryNotStaleGreen (chatgpt and opencode-go; with a staged milestone: the reset carries the stage navigation, which names the evidence as historical for its tree) |
| test/integration/open_code_go_login_test.exs | installed #{@provider} piped login rejects invalid UTF-8 instead of saving a replacement key | TestInstalledKeyLoginUnderPipesAndATerminal (`<provider> piped invalid UTF-8`, the ExUnit Python driver unchanged against the real built binary, for opencode-go, anthropic and openai-compatible) |
| test/integration/open_code_go_login_test.exs | installed #{@provider} terminal input never echoes and restores state on success, error and each signal | TestInstalledKeyLoginUnderPipesAndATerminal (`<provider> terminal`: a real pseudo-terminal; success, empty, SIGINT 130, SIGTERM 143, SIGHUP 129; echo off, terminal restored, key never echoed, saved bytes kept) |
| test/integration/review_material_test.exs | fitted inline source relocates on pressure (historical=#{historical}) | TestFittedInlineSourceRelocatesOnPressure (both subtests) |
| test/integration/integration_helpers_test.exs | marker readiness exceeds the former deadline and missing markers name their path | installed: deterministic-check-gate "Delayed readiness and test-owner shutdown have deterministic outcomes" (`delayedMarker` 11 s marker accepted with a 60 s wait; `missingMarker` names its path) |
| test/integration/integration_helpers_test.exs | cleanup retains custody after owner #{@reason} | installed: deterministic-check-gate lifecycle `normal` and `aborted` owners (a separate Node owner ends normally or is SIGKILLed; the custodian still stops kogen and its child, removes the root and leaves an unrelated process alive) |
| test/integration/integration_helpers_test.exs | project preparation #{@outcome} stops descendants before removing its workspace | installed: deterministic-check-gate lifecycle (`childStopped` and `rootRemoved` for both owners); obsolete in part: the ExUnit project-preparation helper is gone, and `go_driver_support.js` kills every spawned process group before it removes its work directory |
| test/integration/integration_helpers_test.exs | a failed invocation reaps descendants even when its parent has already exited | obsolete harness assertion (ExUnit `Helpers.kogen!` process custody). Its safety outcome for Kogen itself is covered by TestRunStdinClosedOwnGroup, TestKilledKogenStopsCommands and TestInterruptKillsAGroupThatIgnoresSIGTERM in `cli/sys` and the deterministic-check-gate lifecycle `cliStopped`/`childStopped` checks on the real relay and kogen pids |
| test/integration/integration_helpers_test.exs | a startup error does not destroy custody of an already running invocation | obsolete harness assertion (ExUnit helper bookkeeping of concurrent invocations); `go_driver_support.js` tracks each spawned group independently (`groups` set) and kills only its own |
| test/integration/integration_helpers_test.exs | already completed invocations clean up harmlessly | obsolete harness assertion (ExUnit helper cleanup of finished invocations); `go_driver_support.js` `killGroup` ignores an already-exited group (ESRCH) |
