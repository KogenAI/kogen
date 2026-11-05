Feature: kogen's kogen-build recover tests ground their blocker claim

  Scenario: The kogen-build consumes suite passes at the pinned kogen-build and at 2e10d93
    Then k-consumes-build-recover-grounded: the kogen-build consumes suite passes with kogen-build "pinned"
    And k-consumes-build-recover-grounded: the kogen-build consumes suite passes with kogen-build "v0.0.0-20261104030858-2e10d934cac2"

  Scenario: A blocker claim that no failing verification backs fails the archive test
    Then k-consumes-build-recover-grounded: the kogen-build consumes suite passes with kogen-build "v0.0.0-20261104030858-2e10d934cac2"
    And k-consumes-build-recover-grounded: with the fixture checks dropped the archive test fails with kogen-build "v0.0.0-20261104030858-2e10d934cac2"
