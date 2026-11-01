Feature: The example check substitutes Scenario Outline placeholders before comparing
  The installed release shapes a prepared outline package through the scripted local provider. Kogen gives its example
  check every Scenario Outline expanded, one Scenario per Examples row with that row's values in place of the
  placeholders, and checks the scripted answers' quotes against that expanded text. The outline features are prepared
  fixture files in features/steps/k_examples_outline/; their step definitions are trivial.

  Scenario: The reported outline, answered with its placeholder step as the expected value, shapes and approves unchanged
    Given the outline package "yield-regressions" states the rule "The existing tests in the scenario outline pass before and after."
    And the example check answers outline candidate 1 with:
      | scenario                                                             | input                            | expected                                                                     | rule                                                              | derived                                                                                                  | why                                                                                   |
      | Existing shell lifecycle, retrieval and attempt cleanup keep passing | TestShellLifecycleSuccessCleanup | the yield snapshot regression "<test>" in package "<package>" ran and passed | The existing tests in the scenario outline pass before and after. | the yield snapshot regression "TestShellLifecycleSuccessCleanup" in package "./conformance" ran and passed | TestShellLifecycleSuccessCleanup in ./conformance is an existing test, so it passes |
      | Existing shell lifecycle, retrieval and attempt cleanup keep passing | TestShellYieldRetrievalScope     | the yield snapshot regression "<test>" in package "<package>" ran and passed | The existing tests in the scenario outline pass before and after. | the yield snapshot regression "TestShellYieldRetrievalScope" in package "./tools" ran and passed           | TestShellYieldRetrievalScope in ./tools is an existing test, so it passes           |
    When the shaper submits the outline fixture "yield-regressions"
    Then shaping the outline package exited with status 0
    And the example check requests offered only the tool "submit_example_check" and gave the checker, in order, the request, the candidate intent.md and the acceptance text of "yield-regressions.expanded"
    And the outline package's shaping events record example check results "unquoted+unquoted"
    And shaping the outline package printed the line "Next: kogen intent approve yield-regressions"
    And the published outline package is exactly the one with the fixture "yield-regressions"
    And the approval card of the outline package exits 5 and lists "Existing shell lifecycle, retrieval and attempt cleanup keep passing (2 examples) (passes now)"
    And approving the outline package with its full hash exits 0, prints "approved yield-regressions" and the first eight characters of that hash, and writes an approval marker

  Scenario: A consistent Scenario Outline whose rows the checker derives from the expanded text shapes and approves unchanged
    Given the outline package "durations" states the rule "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
    And the example check answers outline candidate 1 with:
      | scenario                                          | input | expected                       | rule                                                                          | derived                        | why                        |
      | 3725 seconds render as hours, minutes and seconds | 3725  | 1 hour, 2 minutes, 5 seconds   | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | 1 hour, 2 minutes, 5 seconds   | 3725 = 1*3600 + 2*60 + 5   |
      | 5430 seconds render as hours, minutes and seconds | 5430  | 1 hour, 30 minutes, 30 seconds | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | 1 hour, 30 minutes, 30 seconds | 5430 = 1*3600 + 30*60 + 30 |
    When the shaper submits the outline fixture "durations-consistent"
    Then shaping the outline package exited with status 0
    And the example check requests offered only the tool "submit_example_check" and gave the checker, in order, the request, the candidate intent.md and the acceptance text of "durations-consistent.expanded"
    And the outline package's shaping events record example check results "follows+follows"
    And shaping the outline package printed the line "Next: kogen intent approve durations"
    And the published outline package is exactly the one with the fixture "durations-consistent"
    And the approval card of the outline package exits 5 and lists "<seconds> seconds render as hours, minutes and seconds (2 examples) (passes now)"
    And approving the outline package with its full hash exits 0, prints "approved durations" and the first eight characters of that hash, and writes an approval marker

  Scenario: The same outline with one contradicting row is still refused naming that row, and its consistent version is accepted
    Given the outline package "durations" states the rule "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
    And the example check answers outline candidate 1 with:
      | scenario                                          | input | expected                     | rule                                                                          | derived                        | why                        |
      | 3725 seconds render as hours, minutes and seconds | 3725  | 1 hour, 2 minutes, 5 seconds | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | 1 hour, 2 minutes, 5 seconds   | 3725 = 1*3600 + 2*60 + 5   |
      | 5430 seconds render as hours, minutes and seconds | 5430  | 1 hour, 1 minute, 30 seconds | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | 1 hour, 30 minutes, 30 seconds | 5430 = 1*3600 + 30*60 + 30 |
    And the example check answers outline candidate 2 with:
      | scenario                                          | input | expected                       | rule                                                                          | derived                        | why                        |
      | 3725 seconds render as hours, minutes and seconds | 3725  | 1 hour, 2 minutes, 5 seconds   | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | 1 hour, 2 minutes, 5 seconds   | 3725 = 1*3600 + 2*60 + 5   |
      | 5430 seconds render as hours, minutes and seconds | 5430  | 1 hour, 30 minutes, 30 seconds | H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | 1 hour, 30 minutes, 30 seconds | 5430 = 1*3600 + 30*60 + 30 |
    When the shaper submits the outline fixture "durations-contradicting", then the outline fixture "durations-consistent"
    Then shaping the outline package exited with status 0
    And after its first outline submission the shaper was told exactly:
      """
      Example check: 1 acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.
      - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And the example check requests offered only the tool "submit_example_check" and gave the checker, in order, the request, the candidate intent.md and the acceptance text of "durations-contradicting.expanded, durations-consistent.expanded"
    And the outline package's shaping events record example check results "follows+contradicts, follows+follows"
    And shaping the outline package printed the line "Next: kogen intent approve durations"
    And the published outline package is exactly the one with the fixture "durations-consistent"
    And the approval card of the outline package exits 5 and lists "<seconds> seconds render as hours, minutes and seconds (2 examples) (passes now)"

  Scenario: An arithmetic contradiction goes back to the shaper and its consistent version is accepted unchanged
    Given the prepared package "durations" states the rule "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
    And the prepared example "5430 seconds render as hours, minutes and seconds" has input "5430"
    And the example check of the prepared package derives "1 hour, 30 minutes, 30 seconds" because "5430 = 1*3600 + 30*60 + 30"
    When the shaper submits the prepared example expecting "1 hour, 1 minute, 30 seconds", then expecting "1 hour, 30 minutes, 30 seconds"
    Then shaping the prepared package exited with status 0
    And after its first prepared submission the shaper was told exactly:
      """
      Example check: 1 acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.
      - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "contradicts, follows"
    And shaping the prepared package printed the line "Next: kogen intent approve durations"
    And the published prepared package is exactly the one expecting "1 hour, 30 minutes, 30 seconds"
    And the approval card of the prepared package exits 5 and lists "5430 seconds render as hours, minutes and seconds (passes now)"

  Scenario: A contradiction the shaper keeps is not marked ready and approval refuses the package
    Given the prepared package "durations" states the rule "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
    And the prepared example "5430 seconds render as hours, minutes and seconds" has input "5430"
    And the example check of the prepared package derives "1 hour, 30 minutes, 30 seconds" because "5430 = 1*3600 + 30*60 + 30"
    When the shaper submits the prepared example expecting "1 hour, 1 minute, 30 seconds" three times
    Then shaping the prepared package exited with status 1
    And shaping the prepared package printed these lines in order:
      """
      intent/not_ready: the Intent is not ready to build
        - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And every example check request offered only the tool "submit_example_check" and carried the request and the candidate package
    And the prepared package's shaping events record example check results "contradicts, contradicts, contradicts"
    And the prepared package has no readiness evidence and no source receipt
    And the approval card of the prepared package exits 1 and printed these lines in order:
      """
      intent/examples_contradict: Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete .kogen/intents/durations/ and shape again
        - scenario: 5430 seconds render as hours, minutes and seconds | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60 | derived: 1 hour, 30 minutes, 30 seconds | why: 5430 = 1*3600 + 30*60 + 30
      """
    And approving the prepared package with its full hash exits 1, prints "intent/examples_contradict: Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete .kogen/intents/durations/ and shape again" and writes no approval marker

  Scenario: The shaping specification and the configuration guide describe the outline expansion
    Then the shaping specification names the example check:
      | path                     | text                          |
      | spec/prose/02-shaping.md | one Scenario per Examples row |
      | docs/configuration.md    | one Scenario per Examples row |
