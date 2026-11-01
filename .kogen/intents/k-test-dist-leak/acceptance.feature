Feature: Test releases cannot contaminate checkout releases
  Tests must leave git status and existing dist content unchanged, package current
  source into their own temporary directories, and preserve installed behavior.
  Delivery additionally runs go test ./... followed by sh test/suite.sh, retaining
  the complete non-live results including both Version works anywhere without a
  login examples and Install into the default prefix and run from anywhere without
  Erlang, Elixir or Go.

  Scenario Outline: Installed usage-limit regressions preserve checkout releases
    Then dist isolation Go test "<name>" passes in package "<package>"
    Examples:
      | name                                  | package |
      | TestUsageLimitPackagingIsolationRound2 | .       |
      | TestUsageLimitPackagingIsolationRound3 | .       |
      | TestBaselinePackagingIsolation        | ./build |
