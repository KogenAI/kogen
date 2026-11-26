Feature: Test Claude Code role-start history snapshots
  This feature verifies new direct tests against the existing Uses behavior and temporary wrong implementations.

  Background:
    Given claude-runtime-use-snapshot-tests: the Claude Code package tests pass with the real Uses

  Scenario: Test complete ordered role-start history
    # After two distinct role starts, require both entries in recording order.
    # Reject latest-only, reversed order, and omission of any of the four fields.
    Then claude-runtime-use-snapshot-tests: the tests require both entries in recording order with role, version, source and path intact

  Scenario: Test that overwrites do not change recorded history
    # Replace an entry in the returned slice; the next read must still return the original history.
    # Reject returning the internal slice directly.
    Then claude-runtime-use-snapshot-tests: the tests detect a caller overwrite changing the next Uses result

  Scenario: Test that appends do not add a recorded start
    # Append a distinct entry to the returned slice; the next read must still return just the original entries.
    # Reject exposing shared view storage and reading the caller-written tail as a recorded start.
    Then claude-runtime-use-snapshot-tests: the tests detect a caller append appearing in the next Uses result
