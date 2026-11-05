Feature: The review card rule asserts the full Intent title line and the approver format
  These scenarios run kogen's own acceptance suite (test/acceptance) against the release archive
  built from this checkout, unchanged or with its kogen passing review cards through a wrapper
  that shows one exact line instead of another.

  Background:
    Given fix-k-acceptance-no-card-hash: the release archive built from this checkout

  Scenario: Card and approval scenarios pass with the stricter card rule
    When fix-k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                               |
      | 03-approval-and-build-start.feature | The review card shows the Intent, its scenarios and its files          |
      | 03-approval-and-build-start.feature | Approving with the card's hash records the approval and starts nothing |
      | 03-approval-and-build-start.feature | A new baseline hash makes approval rerun readiness                     |
    Then fix-k-acceptance-no-card-hash: every listed scenario passed

  Scenario: A review card with a wrong Intent title turns the card scenario red
    Given fix-k-acceptance-no-card-hash: the release's kogen shows the line "Intent: is-even — Add an is-odd helper" instead of "Intent: is-even — Add an is-even helper" in its review cards
    When fix-k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                      |
      | 03-approval-and-build-start.feature | The review card shows the Intent, its scenarios and its files |
    Then fix-k-acceptance-no-card-hash: the release's kogen replaced the line "Intent: is-even — Add an is-even helper" in a review card
    And fix-k-acceptance-no-card-hash: the scenario "The review card shows the Intent, its scenarios and its files" failed at its step "stdout shows the review card of "is-even"" with the message:
      """
      review card of is-even has no line "Intent: is-even — Add an is-even helper"
      """

  Scenario: A review card whose approver is not Name <email> turns the card scenario red
    Given fix-k-acceptance-no-card-hash: the release's kogen shows the line "Approver: Kogen Acceptance" instead of "Approver: Kogen Acceptance <kogen@example.invalid>" in its review cards
    When fix-k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                      |
      | 03-approval-and-build-start.feature | The review card shows the Intent, its scenarios and its files |
    Then fix-k-acceptance-no-card-hash: the release's kogen replaced the line "Approver: Kogen Acceptance <kogen@example.invalid>" in a review card
    And fix-k-acceptance-no-card-hash: the scenario "The review card shows the Intent, its scenarios and its files" failed at its step "stdout shows the review card of "is-even"" with the message:
      """
      review card of is-even has no line "Approver: <name> <<email>>"
      """

  Scenario: A review card passed through the same wrapper unchanged stays green
    Given fix-k-acceptance-no-card-hash: the release's kogen passes its review cards through unchanged
    When fix-k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                      |
      | 03-approval-and-build-start.feature | The review card shows the Intent, its scenarios and its files |
    Then fix-k-acceptance-no-card-hash: the release's kogen passed a review card through
    And fix-k-acceptance-no-card-hash: every listed scenario passed
