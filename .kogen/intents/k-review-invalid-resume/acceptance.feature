Feature: Resume a green Build stopped by an invalid review verdict, whatever executor reviews it
  The real kogen program, built from this checkout, runs `kogen intent build`, `kogen intent inspect`
  and `kogen intent resume` against temporary fixture projects and a scripted provider whose
  independent reviewer ends without a valid verdict after the builder's candidate passed every
  check. The Claude Code case runs the real Build and resume entries in process with a scripted
  Claude Code reviewer and the real `kogen intent inspect`. No real model, account or network is used.

  Scenario: A provider-route review that left uncommitted edits and ended without a valid verdict resumes with one fresh review of the green candidate
    When the k-review-invalid-resume driver observes "native-edits"
    Then the Build stopped with review_invalid and a review-only checkpoint of the green candidate, the reviewer's edits left in place
    And kogen intent inspect reports the stopped Build's resume as potentially available
    And its resume discarded the stopped review's edits, ran only one fresh review of the unchanged green candidate and landed it

  Scenario: A provider-route review whose red repair went back to it and that then ended without a valid verdict resumes from the builder's green candidate
    When the k-review-invalid-resume driver observes "native-repaired"
    Then the Build stopped with review_invalid and a review-only checkpoint of the green candidate, the reviewer's edits left in place
    And kogen intent inspect reports the stopped Build's resume as potentially available
    And its resume discarded the stopped review's edits, ran only one fresh review of the unchanged green candidate and landed it

  Scenario: An invalid verdict on the resumed review stops as it does today
    When the k-review-invalid-resume driver observes "native-resumed-invalid"
    Then the Build stopped with review_invalid and a review-only checkpoint of the green candidate, the reviewer's edits left in place
    And kogen intent inspect reports the stopped Build's resume as potentially available
    And its resume discarded the stopped review's edits and the fresh review's invalid ending stopped again with no automatic retry and nothing committed

  Scenario: A Claude Code review that left uncommitted edits and ended without a valid verdict resumes the same way
    When the k-review-invalid-resume driver observes "external-edits"
    Then the Build stopped with review_invalid and a review-only checkpoint of the green candidate, the reviewer's edits left in place
    And kogen intent inspect reports the stopped Build's resume as potentially available
    And its resume discarded the stopped review's edits, ran only one fresh review of the unchanged green candidate and landed it
