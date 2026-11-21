Feature: The archive mode observer expects the docs the release script ships
  This feature checks that the observer behind the public archive modes scenario lists exactly the docs that packaging/package.sh copies into the archive. It needs no model and no network.

  Scenario: The observer and the release script agree on the shipped docs
    Given main-health-24169a: the release script and the archive mode observer are read
    Then main-health-24169a: the release script still copies the Providers guide into the archive docs
    And main-health-24169a: the observer expects exactly the docs the release script copies
    And main-health-24169a: every doc the observer expects exists in the docs folder
