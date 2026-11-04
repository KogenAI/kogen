Feature: Keep the shaping consumer fixture compatible
  Scenario: Separate fixture author and title
    Then k-consumes-kogen-fixture-user: the fixture title excludes its Git user name

  Scenario: Assert the relevant approval blocker without incidental cardinality
    Then k-consumes-kogen-fixture-user: the approval blocker assertion is not singleton or positional

  Scenario Outline: Run the actual consumes contract with both coordinator versions
    Then k-consumes-kogen-fixture-user: the shaping consumes suite passes with coordinator "<version>"

    Examples:
      | version                          |
      | pinned                           |
      | v0.0.0-20261103212139-91d0a325d982 |
