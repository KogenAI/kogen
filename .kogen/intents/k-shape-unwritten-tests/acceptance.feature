Feature: Shaping refuses acceptance that runs tests nobody has written, and a builder told what is missing acts or stops
  The installed release runs against the scripted local provider of go_driver_support.js, in disposable fixture
  projects. The shaped fixture is a small Go module: widget.Double still returns its input, TestWidgetExists exists
  and TestWidgetDoubles does not. No real provider, account, or Go test name of this Build is involved.

  Scenario: A named-test package is refused, also when resubmitted unchanged, and the behavioural package is published
    When the unwritten-tests shaper submits the named-test package, resubmits it unchanged, then submits the behavioural package and acknowledges it
    Then the unwritten-tests shape exited with status 0 after 4 shaping requests
    And the published unwritten-tests package is the behavioural package
    And the feedback to unwritten-tests submissions 1 and 2 was exactly:
      """
      Acceptance depends on tests the Build would have to invent: 1 scenario(s) run named tests that do not exist before the Build; nothing was published. Acceptance must observe behaviour that any correct implementation produces (run the program, call the code or inspect its output), not test names or files the Build has to write. Rewrite these steps; resubmitting them unchanged is refused again.
      - The doubling test passes (line 2): TestWidgetDoubles: did not run (no tests to run)
      """
    And the feedback to unwritten-tests submission 3 is readiness observations, not a refusal
    And the unwritten-tests shaping events record 2 submission_refused events with gate "unwritten_tests"
    And the first unwritten-tests shaping request instructions contain:
      """
      Unwritten tests: acceptance must not depend on test names or files the Build has to invent. A step may run a named test only when that test already exists before the Build; Shape refuses a candidate whose acceptance runs a named test that did not run on the unchanged tree. Observe behaviour that any correct implementation produces instead.
      """

  Scenario: A shaper that keeps submitting the named-test package ends not ready with the reason
    When the unwritten-tests shaper submits the named-test package three times
    Then the unwritten-tests shape exited with status 1 after 3 shaping requests
    And the unwritten-tests shape printed these lines in order:
      """
      intent/not_ready: the Intent is not ready to build
      - The doubling test passes (line 2): TestWidgetDoubles: did not run (no tests to run)
      """
    And the unwritten-tests shaping events record 3 submission_refused events with gate "unwritten_tests"

  Scenario: A builder that answers the missing-items notice without a tool call stops at the next pass
    When the unwritten-tests fake builder edits once and then answers without a tool call in the case "stuck"
    Then the unwritten-tests Build exited with status 1 after 4 builder requests with outcome "no_progress"
    And the unwritten-tests Build ran 3 verification passes
    And the unwritten-tests Build printed these lines in order:
      """
      candidate/no_progress: the builder was told which required acceptance items are missing and answered again without a tool call; verification pass 3 is the same red as the pass before it; edits are left in place
      missing: failed: The candidate app (line 2)
      """
    And the unwritten-tests builder request 4 begins with this notice and then pass 2's feedback:
      """
      Required acceptance items are still missing: verification pass 2 is the same red as the pass before it, and your last round ended without a tool call. The Build is not complete until each of these acceptance scenarios passes:
      - failed: The candidate app (line 2)
      Act on them now with your tools (change the code and the tests it needs), then call finish. If a correct implementation cannot make them pass because a protected acceptance file is wrong, call report_blocker with its paths, the contradiction and your observed evidence instead. Another round without a tool call into the same red stops the Build as no_progress.
      """
    And the unwritten-tests Build left app.txt as "started" and HEAD unchanged

  Scenario: A builder that answers the missing-items notice with report_blocker stops as build_blocked
    When the unwritten-tests fake builder edits once and then answers without a tool call in the case "blocker"
    Then the unwritten-tests Build exited with status 1 after 4 builder requests with outcome "build_blocked"
    And the unwritten-tests Build printed these lines in order:
      """
      candidate/build_blocked: BUILDER-REPORTED protected-baseline contradiction; edits are left in place; this report is not independently proven
      """
    And the unwritten-tests builder request 4 begins with this notice and then pass 2's feedback:
      """
      Required acceptance items are still missing: verification pass 2 is the same red as the pass before it, and your last round ended without a tool call. The Build is not complete until each of these acceptance scenarios passes:
      - failed: The candidate app (line 2)
      Act on them now with your tools (change the code and the tests it needs), then call finish. If a correct implementation cannot make them pass because a protected acceptance file is wrong, call report_blocker with its paths, the contradiction and your observed evidence instead. Another round without a tool call into the same red stops the Build as no_progress.
      """
    And the unwritten-tests Build left app.txt as "started" and HEAD unchanged
