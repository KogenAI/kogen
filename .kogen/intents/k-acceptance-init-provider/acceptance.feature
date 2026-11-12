Feature: kogen's acceptance does not pin kogen-setup's init wording
  This feature checks that the init-without-login scenario asserts kogen's outcome only.

  Scenario: Init without a login asserts the outcome, not setup's stdout wording
    Given k-acceptance-init-provider: the scenario "Init without a login writes nothing" is read from "spec/features/01-project-setup.feature"
    Then k-acceptance-init-provider: it does not pin setup wording
    And k-acceptance-init-provider: it has the step "Then the exit code is 4"
    And k-acceptance-init-provider: it has the step "And stdout contains \"provider/login\""
    And k-acceptance-init-provider: it has the step "And the file \".kogen/project.yaml\" does not exist"
    And k-acceptance-init-provider: it has the step "And the working tree is unchanged"
