Feature: Kogen's acceptance checks the review card's content, not a SHA-256 baseline
  These scenarios run scenarios of kogen's own acceptance suite (test/acceptance) against
  real release archives: the one built from this checkout with kogen's current component
  pins, one whose kogen is rebuilt with the 04:24Z adoption window's component tuple, and
  ones whose kogen passes its review cards through a wrapper that can drop one line.

  Background:
    Given k-acceptance-no-card-hash: the release archive built from this checkout

  Scenario: Card and approval scenarios pass with kogen's current component pins
    When k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                                               |
      | 03-approval-and-build-start.feature | The review card shows the Intent, its scenarios and its files                          |
      | 03-approval-and-build-start.feature | Approving with the card's hash records the approval and starts nothing                 |
      | 03-approval-and-build-start.feature | A new baseline hash makes approval rerun readiness                                     |
      | 03-approval-and-build-start.feature | A not-ready Intent has no card and cannot be approved                                  |
      | claude-code-full-lineup.feature     | Refine publishes only owned permitted corrections and revokes approval only on success |
    Then k-acceptance-no-card-hash: every listed scenario passed

  Scenario: Card and approval scenarios pass with the 04:24Z window's component tuple
    Given k-acceptance-no-card-hash: the release's kogen is rebuilt with kogen-loop "cfa9b06" and these component versions:
      | module                                | version                            |
      | github.com/KogenAI/kogen-coordinator  | v0.0.0-20261103204401-482d5656e610 |
      | github.com/KogenAI/kogen-shaping      | v0.0.0-20261103232202-3a95bc566617 |
      | github.com/KogenAI/kogen-review       | v0.0.0-20261103231148-9d8ff687f8c1 |
      | github.com/KogenAI/kogen-build        | v0.0.0-20261103231148-748c085cf3c6 |
      | github.com/KogenAI/kogen-executor     | v0.0.0-20261103234441-96c899f23ebf |
      | github.com/KogenAI/kogen-verification | v0.0.0-20261103201747-3cb7305a5690 |
      | github.com/KogenAI/kogen-setup        | v0.0.0-20261103233614-b6f5939b7cbe |
    When k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                                               |
      | 03-approval-and-build-start.feature | The review card shows the Intent, its scenarios and its files                          |
      | 03-approval-and-build-start.feature | Approving with the card's hash records the approval and starts nothing                 |
      | 03-approval-and-build-start.feature | A new baseline hash makes approval rerun readiness                                     |
      | 03-approval-and-build-start.feature | A not-ready Intent has no card and cannot be approved                                  |
      | claude-code-full-lineup.feature     | Refine publishes only owned permitted corrections and revokes approval only on success |
    Then k-acceptance-no-card-hash: every listed scenario passed

  Scenario: A review card without its Files section turns acceptance red
    Given k-acceptance-no-card-hash: the release's kogen drops the line "Files" from its review cards
    When k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                               |
      | 03-approval-and-build-start.feature | Approving with the card's hash records the approval and starts nothing |
    Then k-acceptance-no-card-hash: the release's kogen dropped the line "Files" from a review card
    And k-acceptance-no-card-hash: the scenario "Approving with the card's hash records the approval and starts nothing" failed at its step:
      """
      the caller approves "is-even" with the hash from its review card
      """

  Scenario: A review card that drops a listed path turns acceptance red
    Given k-acceptance-no-card-hash: the release's kogen drops the line "  - features/steps/is_even_steps.js" from its review cards
    When k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                               |
      | 03-approval-and-build-start.feature | Approving with the card's hash records the approval and starts nothing |
    Then k-acceptance-no-card-hash: the release's kogen dropped the line "  - features/steps/is_even_steps.js" from a review card
    And k-acceptance-no-card-hash: the scenario "Approving with the card's hash records the approval and starts nothing" failed at its step:
      """
      the caller approves "is-even" with the hash from its review card
      """

  Scenario: A review card passed through the same wrapper unchanged stays green
    Given k-acceptance-no-card-hash: the release's kogen passes its review cards through unchanged
    When k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:
      | feature                             | scenario                                                               |
      | 03-approval-and-build-start.feature | Approving with the card's hash records the approval and starts nothing |
    Then k-acceptance-no-card-hash: the release's kogen passed a review card through
    And k-acceptance-no-card-hash: every listed scenario passed

  Scenario: No acceptance baseline hash comparison of component output remains
    When k-acceptance-no-card-hash: the command "grep -rn 'acceptance baseline' test/acceptance" runs in the checkout
    Then k-acceptance-no-card-hash: no line it printed compares a hash
    And k-acceptance-no-card-hash: no file under "test/acceptance" outside node_modules contains "baselineHash"
