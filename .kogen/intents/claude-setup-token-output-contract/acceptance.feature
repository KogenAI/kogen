Feature: Add direct coverage of Claude setup-token output handling
  This feature closes the screen handling test gap without changing SetupToken.
  It checks that the Go tests catch wrong behavior in the real screen writer and
  parser. Real browser sign-in, network access, and runtime installation are excluded.

  Background:
    Given claude-setup-token-output-contract: the Claude Code package tests pass on the unchanged implementation

  Scenario: A split marker and split token never reach forwarded output
    For example, write "Open the browser.\nYour OAuth", " token:\n  fake-",
    and "token_123\n" separately. The output is exactly "Open the browser.\n".
    Then claude-setup-token-output-contract: the tests reject "finding the marker only within a single write"
    And claude-setup-token-output-contract: the tests reject "dropping the text before a split marker"

  Scenario: A whole marker hides its token and all later writes
    For example, write "Open the browser.\nYour OAuth token:\n  fake-token_123\n"
    and then "Store this token securely.\n". The output is exactly
    "Open the browser.\n" both before and after the second write.
    Then claude-setup-token-output-contract: the tests reject "forwarding token text after a whole marker in the same write"
    And claude-setup-token-output-contract: the tests reject "forwarding later writes after a whole marker"

  Scenario: Only trimmed token text after the marker is returned
    For example, "Open the browser.\nYour OAuth token:\n  fake-token_123 \t\n"
    returns "fake-token_123"; "arbitrary-screen-text\n" and
    "Your OAuth token:\n \t\n" each return the empty string.
    Then claude-setup-token-output-contract: the tests reject "returning the token without trimming it"
    And claude-setup-token-output-contract: the tests reject "accepting arbitrary screen text without a marker"
    And claude-setup-token-output-contract: the tests reject "returning a nonempty token when only the marker is present"
