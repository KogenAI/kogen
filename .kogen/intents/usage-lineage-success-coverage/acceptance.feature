Feature: Usage lineage success coverage
  This feature checks that the Go tests in cli/usage_test.go cover successful lineage selection through the usage command, by showing they fail when the command is wrong.

  Scenario: Lineage selection never stops at the requested run
    Given usage-lineage-success-coverage: a scratch copy of the cli module
    Then usage-lineage-success-coverage: the usage tests reject selecting only the requested run

  Scenario: Lineage selection never includes every run
    Given usage-lineage-success-coverage: a scratch copy of the cli module
    Then usage-lineage-success-coverage: the usage tests reject selecting every run

  Scenario: Lineage scope reports lineage selection enabled
    Given usage-lineage-success-coverage: a scratch copy of the cli module
    Then usage-lineage-success-coverage: the usage tests reject reporting lineage selection as disabled

  Scenario: Lineage scope identifies the requested run
    Given usage-lineage-success-coverage: a scratch copy of the cli module
    Then usage-lineage-success-coverage: the usage tests reject omitting the requested run id from the scope

  Scenario: Lineage selection includes the sibling with the same root build
    Given usage-lineage-success-coverage: a scratch copy of the cli module
    Then usage-lineage-success-coverage: the usage tests reject ignoring the shared root build

  Scenario: Lineage selection includes the original run of the resumed chain
    Given usage-lineage-success-coverage: a scratch copy of the cli module
    Then usage-lineage-success-coverage: the usage tests reject not following resumed_from to the original run
