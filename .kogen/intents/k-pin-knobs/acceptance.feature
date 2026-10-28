Feature: Internal loop research knobs
  Scenario Outline: Pin and wiring contract tests execute
    When I run the loop knob contract test "<test>" in "<directory>"
    Then the loop knob contract test "<test>" passes
    Examples:
      | directory | test |
      | cli | TestLoopPinKnobsProvenance |
      | cli | TestLoopPin |
      | cli/shape | TestLoopKnobsShape |
      | cli/shape | TestLoopKnobsRefine |
      | cli/build | TestLoopKnobsReview |
      | cli/build | TestLoopKnobsNativeBuilder |
      | cli | TestLoopKnobsZeroCompatibility |
      | cli | TestLoopKnobsInvalidStartup |

  Scenario: Vendored library checks
    When I run the pinned loop race suite
    Then the pinned loop race suite succeeds
