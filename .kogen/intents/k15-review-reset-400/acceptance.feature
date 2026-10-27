Feature: A native Anthropic review continues validly after a working-window reset (KOGEN-066)

  Scenario: The validating fake Messages API accepts a valid request and rejects each invalid shape
    Then the k15 Go test "TestK15ValidatorAcceptsValidAndRejectsInvalidShapes" runs and passes

  Scenario: A review that resets its working window and continues sends a request the validating fake accepts
    Then the k15 Go test "TestK15ReviewResetThenContinueIsValidForAnthropic" runs and passes

  Scenario: The old post-reset request shape is rejected by the same validating fake
    Then the k15 Go test "TestK15OldPostResetShapeIsRejected" runs and passes

  Scenario: Loop-side diagnosability change is reported precisely and the vendored loop is untouched
    Then the k15 loop change note "docs/kogen-066-loop-change.md" contains "messagesFailure"
    And the k15 loop change note "docs/kogen-066-loop-change.md" contains "provider/respond.go"
    And the k15 loop change note "docs/kogen-066-loop-change.md" contains "hostMessage"
    And the k15 loop change note "docs/kogen-066-loop-change.md" contains "300 bytes"
    And the k15 loop change note "docs/kogen-066-loop-change.md" contains "error.type"
    And the k15 loop change note "docs/kogen-066-loop-change.md" contains "messages_test.go"
    And the k15 vendored loop and its pin are unchanged
