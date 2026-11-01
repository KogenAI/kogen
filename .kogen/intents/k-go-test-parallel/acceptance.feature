Feature: Safe Go test process parallelism
  Approval exercises a small real fixture, never the long Kogen suites.
  The final scope cut excludes measurements and timing acceptance.

  Scenario: Independent process-global fixtures run together safely
    When I exercise isolated Go tests in mode "pass"
    Then the isolated Go test observations are:
      """json
      {"exit":0,"tests":{"TestA":"pass","TestB":"pass","TestOutcome":"pass"}}
      """

  Scenario: A failing isolated child fails its named parent and cleans up
    When I exercise isolated Go tests in mode "fail"
    Then the isolated Go test observations are:
      """json
      {"exit":1,"tests":{"TestA":"pass","TestB":"pass","TestOutcome":"fail"},"message":"isolated failure 1414"}
      """

  Scenario: A skipped isolated child is not reported as a pass
    When I exercise isolated Go tests in mode "skip"
    Then the isolated Go test observations are:
      """json
      {"exit":0,"tests":{"TestA":"pass","TestB":"pass","TestOutcome":"skip"},"message":"isolated skip 3141"}
      """
