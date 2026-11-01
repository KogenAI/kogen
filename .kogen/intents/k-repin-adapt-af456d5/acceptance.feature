Feature: Adapt Kogen to kogen-loop af456d5
  The re-pin commit already holds the vendored loop and cli/loop-pin.json; both stay
  unchanged. Focused regressions cover what the re-pin turned red: pinned request bytes
  and shell tool text are the af456d5 values, Kogen's tests make no claim about the loop's
  default instructions, the specification states the pinned shell waits, and the
  window-reset building scenario passes under the loop's 131072-byte visible-output bound
  while keeping every assertion it had (<n> stands for any request number). The
  configured checks remain the final Build gate.

  Scenario: Pinned request bytes and tool text are the af456d5 values
    When af456d5 adaptation runs these Go tests:
      | package | test                                     |
      | .       | TestResearchRemovalDefaults              |
      | ./agent | TestDefinitionsMatchTheElixirDefinitions |
      | ./build | TestKRevodGatePartsUnchanged             |
      | ./build | TestNamedFeedbackCompatibility           |
      | ./build | TestContextExternalNativeBytes           |
      | ./build | TestKReviewRetryUnchangedValidRequests   |
    Then af456d5 adaptation observed each of those Go tests run once and pass

  Scenario: Kogen's tests make no claim about the loop's default instructions
    Then af456d5 adaptation finds none of these texts in Kogen's tests outside the vendored loop:
      | text                   |
      | DefaultInstructions    |
      | call finish right away |
      | You are a coding agent |

  Scenario: The specification states the pinned shell waits
    Then af456d5 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" contains "one second"
    And af456d5 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" contains "30 seconds"
    And af456d5 adaptation finds the "LOOP-5" paragraph of "spec/prose/04-building.md" does not contain "and waits at most one second"

  Scenario: The window-reset building scenario passes and still proves both resets
    When af456d5 adaptation runs the building scenario "Completed builder and independent reviewer windows reset locally"
    Then af456d5 adaptation finds that building scenario tagged "@LOOP-9 @LOOP-10 @REV-2 @model:build" with these steps:
      | step                                                                              |
      | Given the Intent "is-even" from fixture "is-even" is approved                     |
      | And the fake ChatGPT server plays script "build-local-windows"                    |
      | When the caller runs "kogen intent build is-even"                                 |
      | Then the exit code is 0                                                           |
      | And stderr contains "build local reset"                                           |
      | And stderr contains "review local reset"                                          |
      | And stderr contains "ceiling 524288; reserve 131072"                              |
      | And request <n> contains the text of the file ".kogen/intents/is-even/intent.md"  |
      | And request <n> contains "Local working-window reset"                             |
      | And the review request <n> contains "Local working-window reset"                  |
      | And the review request <n> contains "Source provenance: unavailable (legacy)"     |
      | And the review request <n> contains "# Pinned complete candidate source evidence" |
      | And the review request <n> contains "review_delivery"                             |
      | And the review request <n> contains "review_source"                               |
    And af456d5 adaptation observed that building scenario run once and pass
