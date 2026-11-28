Feature: Test bounded stderr persistence accounting
  This feature verifies new direct tests against the existing stderrPersistence.Write behavior and temporary wrong implementations.

  Background:
    Given bounded-stderr-persistence-tests: the Claude Code package tests pass with the real stderrPersistence

  Scenario: Count the overflow of writes that cross the cap
    # Writes crossing the cap return the full length with no error, retain at most the cap and count every unretained byte as lost.
    # Reject tests that check only retained output, and implementations that miscount loss or return a short count.
    Then bounded-stderr-persistence-tests: the tests require writes that cross the cap to return the full length with no error, retain at most the cap and count every unretained byte as lost

  Scenario: Count the unwritten portion of a short write
    # A short underlying write counts the unwritten portion as lost while Write still accepts the full input.
    # Reject tests that use only a fully successful writer.
    Then bounded-stderr-persistence-tests: the tests require a short underlying write to count the unwritten portion as lost while Write accepts the full input

  Scenario: Count writes after the cap is exhausted
    # A later write after the cap is exhausted increases lost by its full length without increasing kept.
    # Reject tests that check only the first write.
    Then bounded-stderr-persistence-tests: the tests require a write after the cap is exhausted to add its full length to lost without increasing kept
