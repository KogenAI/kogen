Feature: No stale thinking blocks after a Shape or Refine working-window reset

  Scenario: The shared stripper removes only thinking blocks
    Then the k18b Go test "TestStripThinkingKeepsOtherBlocksAndDoesNotMutate" in package "./thinking" runs and passes

  Scenario: A native shape that resets its working window continues against the binding-aware fake, and the unstripped window is rejected
    Then the k18b Go test "TestK18bShapeResetContinuesWithoutStaleThinking" in package "./shape" runs and passes

  Scenario: A native refine that resets its working window behaves the same
    Then the k18b Go test "TestK18bRefineResetContinuesWithoutStaleThinking" in package "./shape" runs and passes

  Scenario: A shape or refine request without a reset is byte-identical
    Then the k18b Go test "TestK18bShapeAndRefineRequestWithoutResetIsByteIdentical" in package "./shape" runs and passes

  Scenario: Build and Review resets behave as in K18
    Then the k18b Go test "TestK18ReviewResetContinuesWithoutStaleThinking" in package "./build" runs and passes
    And the k18b Go test "TestK18BuildResetContinuesWithoutStaleThinking" in package "./build" runs and passes
    And the k18b Go test "TestK18ResetStripsOnlyThinkingAndKeepsNewConversationBlocks" in package "./build" runs and passes
    And the k18b Go test "TestK18RequestWithoutResetIsByteIdentical" in package "./build" runs and passes
    And the k18b Go test "TestK18BindingFakeRejectsForeignSignatures" in package "./build" runs and passes

  Scenario: One shared implementation and no vendored edit
    Then exactly one non-test Go package under cli outside third_party strips thinking blocks and build and shape both use it
    And the k18b vendored loop and its pin are unchanged
