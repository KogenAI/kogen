Feature: Pin conditional include test from any temporary directory
  The conditional include test proves on macOS and Linux that a change in a
  conditionally included file is detected, whatever temporary directory Go uses.

  Scenario: The reported test passes when the temporary directory is reached through a symlink
    Given a temporary directory reached through a symlink
    Then the pin Go test "TestPinExecutableConfiguration" passes from that temporary directory
    And the pin Go test "TestPinExecutableConfiguration/an_included_file_and_a_conditional_include" passes from that temporary directory

  Scenario: The conditional include test still passes from a resolved temporary directory
    Given a temporary directory with no symlink in its path
    Then the pin Go test "TestPinExecutableConfiguration/an_included_file_and_a_conditional_include" passes from that temporary directory

  Scenario: A pin through a symlinked checkout path detects a conditionally included change
    Given a temporary directory with no symlink in its path
    Then the pin Go test "TestPinConditionalIncludeThroughSymlinkedCheckout" passes from that temporary directory
