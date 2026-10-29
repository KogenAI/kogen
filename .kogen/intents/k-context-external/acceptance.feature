Feature: Frozen diagnostic delivery across executors
  Scenario Outline: Diagnostic delivery and compatibility regressions
    When I run the context external regression "<test>"
    Then the context external regression "<test>" ran and passed
    Examples:
      | test                                                                            |
      | TestContextExternalFirstPrompt                                                  |
      | TestContextExternalReviewMatrix                                                 |
      | TestContextExternalNativeBytes                                                  |
      | TestBuildWithDiagnosticDataKeepsItPrivatelyAndSendsItAfterTheOpeningMessage        |
