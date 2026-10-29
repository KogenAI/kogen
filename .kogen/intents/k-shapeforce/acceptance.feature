Feature: Require submission after a tool-free shaping answer
  Tests named below must be implemented as real local fake-provider integration tests,
  using the existing shape fixtures and real Shape and Refine entry points, not canned
  results. No network service or real credentials are needed. Each test covers both
  owners where applicable. All fixtures use temporary directories and only clean up
  processes they started; no synthetic CPU load or process-name termination is allowed.

  Scenario: Recover prose without spending an invalid submission
    # Turn 1 answers in prose with zero calls. Turn 2 must name the terminal submit
    # tool in API tool_choice and submit a valid Intent (or valid existing correction).
    # Supply legitimate discovery/readiness acknowledgments as required; success must
    # publish the valid package. End counts are no_tool_turns=1, invalid_submissions=0.
    # The forced_submit_turn event must match the actual captured request.
    When the submission retry integration test "TestShapeForceRecovery" runs
    Then that submission retry test passed without skipping

  Scenario: Preserve reminder-only fallback
    # A provider lacking usable tool choice keeps the exact current owner-specific
    # reminder, unchanged thinking/model/effort and no forced wire field. Run log
    # records unsupported forcing. A valid subsequent submission can still succeed.
    When the submission retry integration test "TestShapeForceFallback" runs
    Then that submission retry test passed without skipping

  Scenario: Keep the three-refusal boundary
    # Three refused submissions stop Shape/Refine as today, publish no candidate,
    # and log invalid_submissions=3. Also precede these by one prose answer: the
    # first two refusals must not stop; the third must stop, with no_tool_turns=1.
    When the submission retry integration test "TestShapeForceInvalidBudget" runs
    Then that submission retry test passed without skipping

  Scenario: Preserve ordinary wire bytes and scope forced choice
    # Capture full rendered request bytes and relevant headers with deterministic
    # identity. Normal submit sessions match their pre-change expected bytes.
    # Both Responses and Chat Completions force the named terminal tool only on
    # the inference after zero calls; ordinary discovery never triggers forcing.
    # A tool-bearing forced response followed by another inference restores auto.
    When the submission retry integration test "TestShapeForceWireCompatibility" runs
    Then that submission retry test passed without skipping

  Scenario: Bound prose recovery and retain counters across windows
    # Three no-tool answers stop without a fourth inference; invalid_submissions=0,
    # no_tool_turns=3. Each eligible forced turn is logged. Exercise a working-window
    # reset between a no-tool answer and its next request: pending force and both
    # counters survive. Provider-error exits also retain the final counters.
    When the submission retry integration test "TestShapeForceNoToolBound" runs
    Then that submission retry test passed without skipping

  Scenario: Preserve existing default invalid-submission behavior
    When the submission retry integration test "TestSubmissionRetryDefault" runs
    Then that submission retry test passed without skipping
