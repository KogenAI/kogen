Feature: Test Claude Code transcript pruning contract
  This feature verifies new direct tests against the existing pruneTranscripts behavior and temporary wrong implementations.

  Background:
    Given claudecode-transcript-pruning-tests: the Claude Code package tests pass with the real pruneTranscripts

  Scenario: Report an expired transcript removal
    # Expired UUID transcripts are removed and the report records their count and byte size.
    # Reject tests that check only removal, and implementations that miscount removals or bytes.
    Then claudecode-transcript-pruning-tests: the tests require an expired transcript to be removed and the report to record its count and byte size

  Scenario: Keep the current, fresh and non-UUID transcripts
    # The current session transcript, a fresh transcript and an expired non-UUID JSONL file stay in place.
    # Reject implementations that delete any of them.
    Then claudecode-transcript-pruning-tests: the tests require the current session, fresh and non-UUID files to remain in place

  Scenario: Leave a symlink to an expired transcript alone
    # A UUID-named symlink to an expired transcript is neither followed nor removed.
    # Reject implementations that treat it as a regular transcript or examine it through its target.
    Then claudecode-transcript-pruning-tests: the tests require a symlink to an expired transcript to be neither followed nor removed
