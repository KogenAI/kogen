Feature: A Build with missing required acceptance items is told what is missing before it stops

  Scenario: The builder is told the missing scenarios and the Build lands after it writes them
    When the early-stop fake builder writes one of three required scenarios and then answers without a tool call in the case "partial-then-repair"
    Then the builder was told the missing scenarios Second and Third once, wrote them, and the Build landed

  Scenario: A builder that answers the notice without a tool call stops, and the stop names the missing items
    When the early-stop fake builder writes one of three required scenarios and then answers without a tool call in the case "partial-stuck"
    Then the Build stopped as no_progress on the next identical red after the notice, naming the missing scenarios Second and Third

  Scenario: Without missing acceptance items the no_progress stop is unchanged
    When the early-stop fake builder breaks a configured check while acceptance stays green and then answers without a tool call in the case "checks-only"
    Then the Build stopped as no_progress at the first identical red without a missing-items notice, as before
