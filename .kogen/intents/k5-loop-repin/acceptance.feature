Feature: Re-pin the vendored kogen-loop to 33e7f4ec and follow its interface changes

  Scenario: The vendored copy is exactly the clean source at 33e7f4ec
    When I inspect the prepared generic loop pin
    Then the prepared loop pin has exactly this identity:
      """
      {"module":"kogen-loop","protocol":"kogen-loop/v1","library":"loop/v1","digest":"3f99ae913cfe08c356bc0543746ae0ebf581880531081633e8d23559d0a74c2c","files":107,"source_head":"33e7f4ec8ba899fc4aa621127379e5cb26b77648","source_state":"clean","actual_digest":"3f99ae913cfe08c356bc0543746ae0ebf581880531081633e8d23559d0a74c2c","actual_files":107}
      """

  Scenario: The vendored bytes equal the source checkout's tracked files
    When I compare the vendored loop with the clean kogen-loop source checkout
    Then the vendored loop has 107 files, none under .kogen or features, and equals the source checkout when one is available

  Scenario: Probe context and deadline, timeout observation failure, and Anthropic diagnostics keep their contracts
    When I execute the focused loop boundary tests:
      | module                     | package       | test                                                              |
      | cli                        | .             | TestLoopPin                                                       |
      | cli                        | .             | TestUsageLeavesAnthropicInvalidProviderFailureCodeNull            |
      | cli                        | ./verify      | TestProbeDeadlineStopsTheProbeAndReportsTimedOut                  |
      | cli                        | ./verify      | TestProbeCancelledContextStopsTheCustodyWait                      |
      | cli                        | ./verify      | TestProbeTimeoutObservationFailureIsNotATimedOutResult            |
      | cli                        | ./shape       | TestShapeProbeReportsTimeoutObservationFailure                    |
      | cli                        | ./shape       | TestRefineProbeReportsTimeoutObservationFailure                   |
      | cli                        | ./shape       | TestRefineAnthropicInvalidProviderFailureReachesTheResult         |
      | cli                        | ./shape       | TestShapeAnthropicInvalidProviderFailureReachesTheDiagnostic      |
      | cli                        | ./build       | TestBuildAnthropicInvalidProviderFailureReachesResultAndOutcome   |
      | cli                        | ./build       | TestNativeDescriptor                                              |
      | cli                        | ./build       | TestNativeConformance                                             |
      | cli/third_party/kogen-loop | ./tools       | TestToolsMatchTheElixirResults                                    |
      | cli/third_party/kogen-loop | ./conformance | TestEngineOrder                                                   |
    Then each focused loop boundary test executes and passes once

  Scenario: Documentation records the Anthropic map and the re-pin, and no timeout default is added
    When I read the re-pin documentation and the Kogen sources
    Then the specification documents the Anthropic provider failure map and the usage decision
    And a re-pin evidence note names the new commit, 107 files and the new digest while the old evidence keeps its history
    And Kogen sources never set a shell timeout and its probe passes a context
