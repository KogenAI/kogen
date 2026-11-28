Feature: Test harness loading of missing and malformed files
  This feature verifies new direct tests against the existing readHarness behavior and temporary wrong implementations.

  Background:
    Given malformed-harness-read-tests: the Claude Code package tests pass with the real readHarness

  Scenario: Count a missing harness as empty without changes
    # A missing harness file returns an empty Harness and changes nothing on the filesystem.
    # Reject tests that exercise only a present file.
    Then malformed-harness-read-tests: the tests require a missing harness file to load as an empty Harness without creating anything

  Scenario: Discard a malformed harness entirely
    # A malformed JSON harness returns an empty Harness; no field decoded before the error may leak through.
    # Reject tests that check only that loading does not panic.
    Then malformed-harness-read-tests: the tests require a malformed JSON harness to load as an empty Harness with no decoded field kept

  Scenario: Keep the history of a valid harness
    # A valid harness file keeps its checked time, last result and failed versions.
    # Reject tests that cover only failure recovery.
    Then malformed-harness-read-tests: the tests require a valid harness file to keep its checked time, result and failed versions
