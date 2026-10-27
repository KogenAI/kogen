Feature: No stale thinking blocks after a working-window reset (KOGEN-066/067)

  Scenario: The binding-aware fake rejects a thinking block signed under a different prefix with the real message, and accepts one signed under its own prefix
    Then the k18 Go test "TestK18BindingFakeRejectsForeignSignatures" runs and passes

  Scenario: A native review that resets its working window and continues is accepted by the binding-aware fake, and the unstripped window (the old behavior) is rejected with the 400 message
    Then the k18 Go test "TestK18ReviewResetContinuesWithoutStaleThinking" runs and passes

  Scenario: A build-owner reset behaves the same
    Then the k18 Go test "TestK18BuildResetContinuesWithoutStaleThinking" runs and passes

  Scenario: Kept messages lose only thinking blocks, while messages produced after the reset keep theirs until a later reset
    Then the k18 Go test "TestK18ResetStripsOnlyThinkingAndKeepsNewConversationBlocks" runs and passes

  Scenario: A request without a reset is byte-identical to today's for review and build
    Then the k18 Go test "TestK18RequestWithoutResetIsByteIdentical" runs and passes

  Scenario: The earlier K15 validator and reset tests still pass under the binding-aware rules
    Then the k18 Go test "TestK15ValidatorAcceptsValidAndRejectsInvalidShapes" runs and passes
    And the k18 Go test "TestK15ReviewResetThenContinueIsValidForAnthropic" runs and passes
    And the k18 Go test "TestK15OldPostResetShapeIsRejected" runs and passes

  Scenario: The fix needs no beta header and no vendored loop edit
    Then no non-test Go source sends the drop_block binding option or its beta header
    And the k18 vendored loop and its pin are unchanged
