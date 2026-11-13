Feature: Kogen qualifies on the new component pins
  This feature checks that the committing scenario that failed at the base passes.

  Scenario: The verified, approved Build scenario passes
    When k-integrate-pins-20261113t104745z: the spec scenario "spec/features/07-committing.feature:14" is run
    Then k-integrate-pins-20261113t104745z: it exits 0 with that scenario passed
