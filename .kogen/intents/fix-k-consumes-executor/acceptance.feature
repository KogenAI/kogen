Feature: The k-consumes-executor review finding does not reproduce in kogen
  The finding names kogen-executor's consumes tests TestRoleConsumption and
  TestProviderConsumption and that repository's README "Assertion" column.
  None of them is part of this kogen checkout or of the kogen-executor
  version it pins, so there is nothing to change here.

  Scenario: Neither named test exists in kogen's Go tests
    Then fix-k-consumes-executor: no Go test file under "cli" defines "TestRoleConsumption"
    And fix-k-consumes-executor: no Go test file under "cli" defines "TestProviderConsumption"

  Scenario: No README in kogen has an "Assertion" column
    Then fix-k-consumes-executor: no Markdown file in the checkout has a table column headed "Assertion"

  Scenario: The pinned kogen-executor carries no consumes suite
    Given fix-k-consumes-executor: "cli/go.mod" requires "github.com/KogenAI/kogen-executor" at "v0.0.0-20261104021843-9021591798ac"
    Then fix-k-consumes-executor: the module "github.com/KogenAI/kogen-executor" that "cli" resolves has no "consumes" directory
