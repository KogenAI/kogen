Feature: Keep the ten-minute budget exclusive to Build and Review
  Shape must finish productive responses longer than ten minutes without a research knob.

  Scenario: Complete an 800-second Shape response without real waiting
    When I run the loop knob contract test "TestShapeBudgetStreaming800Seconds" in "cli/shape"
    Then the loop knob contract test "TestShapeBudgetStreaming800Seconds" passes

  Scenario: Observe role constants, effective logs and preserved expiry behavior
    When I run the loop knob contract test "TestShapeBudgetRoleContract" in "cli"
    Then the loop knob contract test "TestShapeBudgetRoleContract" passes

  Scenario: Preserve the pinned loop behavior unchanged
    When I run the pinned loop race suite
    Then the pinned loop race suite succeeds
