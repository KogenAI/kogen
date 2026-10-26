Feature: Adopt the extracted loop and Build executors without surrendering delivery custody
  The supplied external candidate is reconciled against base 56eecd572a6e07184863939254a90d9a2dc44e96.
  Source authorship, native request/tool bytes and last-terminal/checkpoint semantics are preserved.
  Kogen still owns approval, baseline and HEAD detection, fixers, actual verification, independent review and checked commit.
  The native default and Build-only Claude Code backend share explicit executor capabilities.
  Claude uses installed subscription auth, not copied credentials or API fallback; feedback is not checkpoint Resume.
  Hooks prevent configured native writes but arbitrary Bash is not sandboxed.
  Fake tests establish deterministic plumbing, never live subscription qualification or native authorship of external source.
  The six caller-reported pre-existing Intent-driver failures remain baseline evidence, not universal suite success.
  Configured checks, separate live qualification, no global install/release/push and final independent review remain required.

  Scenario: Adopt the exact prepared offline generic library without native fixture additions
    When I inspect the prepared generic loop pin
    Then the prepared loop pin has exactly this identity:
      """
      {"module":"kogen-loop","protocol":"kogen-loop/v1","library":"loop/v1","digest":"4e1332b9f0aa686d76040466a965a43a5169ba9295631cf7bb9b8f62fb946638","files":88,"source_head":"bbf3fdd6d2e79b96eab6af23bcd6d66212893388","source_state":"clean","actual_digest":"4e1332b9f0aa686d76040466a965a43a5169ba9295631cf7bb9b8f62fb946638","actual_files":88}
      """

  Scenario: Preserve native bytes, terminal behavior, capability identity and recovery across the extraction
    When I execute the focused loop boundary tests:
      | module                     | package       | test                                                                                      |
      | cli                        | .             | TestLoopPin                                                                               |
      | cli                        | ./project     | TestBuildExecutorSelection                                                                |
      | cli                        | ./project     | TestBuildExecutorConfigurationErrors                                                      |
      | cli                        | ./project     | TestExecutorKeysAreNotAcceptedAnywhereElse                                                 |
      | cli                        | ./project     | TestNativeRoleJSONKeepsItsBytes                                                            |
      | cli                        | ./build       | TestNativeOpeningInputEqualsTheOpeningMessage                                              |
      | cli                        | ./build       | TestNativeFirstRequestCarriesTheOpeningInput                                               |
      | cli                        | ./build       | TestNativeDescriptor                                                                      |
      | cli                        | ./build       | TestNativeConformance                                                                     |
      | cli                        | ./build       | TestNativeCheckpointAndConfigCarryNoExecutorIdentity                                       |
      | cli                        | ./build       | TestNativeSelectionIgnoresDepsExternal                                                     |
      | cli                        | ./build       | TestRecoveryArchivesRawFilteredBinaryModeSymlinkAndDeletedPathsWithoutIndexOrIgnoredChanges |
      | cli                        | ./build       | TestRecoveryRefusals                                                                      |
      | cli/third_party/kogen-loop | ./conformance | TestEngineOrder                                                                           |
      | cli/third_party/kogen-loop | ./conformance | TestSessionFeedbackAnsweringTerminalIsCut                                                  |
      | cli/third_party/kogen-loop | ./conformance | TestSessionResumeLibraryAndMismatch                                                       |
      | cli/third_party/kogen-loop | ./conformance | TestContextEndTerminatesTheShellGroupBeforeRunReturns                                      |
    Then each focused loop boundary test executes and passes once

  Scenario: Preserve the external executor's honest protocol, process and verification boundaries
    When I execute the focused loop boundary tests:
      | module | package               | test                                                          |
      | cli    | .                     | TestExternalExecutorWiring                                    |
      | cli    | .                     | TestInstalledBinaryAnswersTheHookBeforeAnyOtherStartup        |
      | cli    | ./executor/claudecode | TestDescribe                                                  |
      | cli    | ./executor/claudecode | TestAuthGate                                                  |
      | cli    | ./executor/claudecode | TestSettingsFileShape                                         |
      | cli    | ./executor/claudecode | TestArgvRounds                                                |
      | cli    | ./executor/claudecode | TestEnvStrippingInPreflight                                   |
      | cli    | ./executor/claudecode | TestLargePromptsArriveOverStdin                                |
      | cli    | ./executor/claudecode | TestEarlyExitBeforeReadingStdin                               |
      | cli    | ./executor/claudecode | TestInitGateFailures                                          |
      | cli    | ./executor/claudecode | TestLivenessFailure                                           |
      | cli    | ./executor/claudecode | TestDeniedWriteThatRanIsProtocolFailure                        |
      | cli    | ./executor/claudecode | TestUsageMappingStates                                        |
      | cli    | ./executor/claudecode | TestResultFailures                                            |
      | cli    | ./executor/claudecode | TestEventAfterResultIsProtocolFailure                         |
      | cli    | ./executor/claudecode | TestLingeringProcessAfterResultIsStopped                       |
      | cli    | ./executor/claudecode | TestCancellationClassifiedByContext                           |
      | cli    | ./executor/claudecode | TestCloseRefusesRounds                                        |
      | cli    | ./build               | TestExternalFinishClaimOnARedTreeGetsFeedbackNotACommit        |
      | cli    | ./build               | TestExternalNoCallEndingGetsFeedbackLikeAFinishClaim           |
      | cli    | ./build               | TestExternalProtectedMutationStopsWithBaselineChanged         |
      | cli    | ./build               | TestExternalHeadMoveStops                                     |
      | cli    | ./build               | TestExternalRoundLimitKeepsTheCandidate                       |
      | cli    | ./build               | TestExternalRoundLimitDefaultsToTheExecutorsOwn               |
      | cli    | ./build               | TestExternalCheckpointRefusesResume                           |
    Then each focused loop boundary test executes and passes once

  Scenario: Actually execute LOOP-14 LOOP-15 and SET-14 through the installed CLI
    When I execute the installed loop specifications tagged "@LOOP-14 or @LOOP-15 or @SET-14" in:
      | spec/features/01-project-setup.feature |
      | spec/features/04-building.feature      |
    Then exactly these installed loop scenarios execute with every step passing:
      | An executor on the review role is a configuration error                                                          |
      | The Claude Code executor forbids a provider on the build role                                                      |
      | The Claude Code executor produces the candidate and Kogen's own review and single commit land it                   |
      | A finish claim on a red tree returns Kogen's feedback to the same Claude session                                    |
      | The Claude Code hook refuses an Edit of a protected path and the Build still lands                                 |
      | A protected file changed through Bash is not prevented but is detected and nothing is committed                    |
      | A credential route that is not the subscription sign-in is refused before any edit                                 |
      | A Claude Code older than the qualified version is unavailable before any edit                                      |
      | max_rounds leaves the candidate in place and the external checkpoint cannot be resumed                             |

  Scenario: Keep affected native verification and protected-baseline scenarios green
    When I execute the installed loop specifications tagged "@VER-6 or @VER-8 or @VER-9" in:
      | spec/features/05-verifying.feature |
    Then exactly these installed loop scenarios execute with every step passing:
      | A failing pass goes back to the builder and the repair lands                    |
      | Weakening the baseline is refused or stops the Build at once                    |
      | Weakening the baseline is refused or stops the Build at once                    |
      | Weakening the baseline is refused or stops the Build at once                    |
      | write_file refuses a protected path and the Build goes on                       |
      | A clean scratch check that rewrites source makes the pass not green             |
