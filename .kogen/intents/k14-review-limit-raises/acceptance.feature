Feature: Review flags timeout, retry and limit raises

  Scenario: The native reviewer's instructions carry the rule for a raised timeout
    When Kogen reviews a diff that raises "timeout: 600" to "timeout: 1800" with no profile through the native and the external review routes
    Then the native review instructions contain this rule exactly once:
      """
      Limit raises: a change that raises a timeout, deadline, retry or attempt count, size or count limit, or wait duration (in code, configuration, tests or scripts, including go test -timeout, Playwright or cucumber timeouts and ExUnit timeouts) is a blocking finding unless the Intent, or a profile cited in the change, shows that the extra work is needed and cannot be removed. The finding names the file:line, the old and new value, and asks for the profile or a speed-up. Lowering a limit, or adding a new bound where none existed, is not flagged by this rule.
      """
    And both review requests carry the raise from the old value to the new value

  Scenario: The external reviewer's request carries the same rule for a raised timeout
    When Kogen reviews a diff that raises "timeout: 600" to "timeout: 1800" with no profile through the native and the external review routes
    Then the external review request contains this rule exactly once:
      """
      Limit raises: a change that raises a timeout, deadline, retry or attempt count, size or count limit, or wait duration (in code, configuration, tests or scripts, including go test -timeout, Playwright or cucumber timeouts and ExUnit timeouts) is a blocking finding unless the Intent, or a profile cited in the change, shows that the extra work is needed and cannot be removed. The finding names the file:line, the old and new value, and asks for the profile or a speed-up. Lowering a limit, or adding a new bound where none existed, is not flagged by this rule.
      """
    And both review requests carry the raise from the old value to the new value
