Feature: Successful init names the first feature command
  Scenario: Initial and repeated ready init give one final command
    Given k-cli-init-success-names-first-intent-command: a local init fixture "ready"
    When k-cli-init-success-names-first-intent-command: init runs 2 times
    Then k-cli-init-success-names-first-intent-command: every run has this report:
      """
      {"exit":0,"readiness":["ok install","ok git","ok config","ok models"],"next":["Next: kogen intent shape <slug> <request-file>"]}
      """

  Scenario: Missing model login keeps readiness failure and status
    Given k-cli-init-success-names-first-intent-command: a local init fixture "no login"
    When k-cli-init-success-names-first-intent-command: init runs 1 times
    Then k-cli-init-success-names-first-intent-command: every run has this report:
      """
      {"exit":0,"readiness":["ok install","ok git","ok config","fail models"],"next":[]}
      """

  Scenario: Missing acceptance keeps its existing next line
    Given k-cli-init-success-names-first-intent-command: a local init fixture "no acceptance"
    When k-cli-init-success-names-first-intent-command: init runs 1 times
    Then k-cli-init-success-names-first-intent-command: every run has this report:
      """
      {"exit":0,"readiness":["ok install","ok git","ok config","ok models"],"next":["Next: set commands.acceptance in .kogen/project.yaml"]}
      """

  Scenario: Missing checks keeps its existing next line
    Given k-cli-init-success-names-first-intent-command: a local init fixture "no checks"
    When k-cli-init-success-names-first-intent-command: init runs 1 times
    Then k-cli-init-success-names-first-intent-command: every run has this report:
      """
      {"exit":0,"readiness":["ok install","ok git","ok config","ok models"],"next":["Next: add the project's checks to commands.checks in .kogen/project.yaml"]}
      """

  Scenario: Both documented init output blocks match the new real suffix
    Given k-cli-init-success-names-first-intent-command: a local init fixture "ready"
    When k-cli-init-success-names-first-intent-command: init runs 1 times
    Then k-cli-init-success-names-first-intent-command: the guide init blocks end like the real report:
      """
      ok install - <version>; node, cucumber and quint run
      ok git - repository <repo>
      ok config - .kogen/project.yaml is valid
      ok models - shape, build, review ready
      Next: kogen intent shape <slug> <request-file>
      """
