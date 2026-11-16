Feature: Consumer fixtures accept the landed producer contracts
  This feature checks the three aggregate consumer scenarios and their tolerance of additive diagnostics.

  Scenario: Init invalid scenario requires the primary diagnostic and tolerates additive context
    Given qualify-frozen-corrective-consumer: the three consumer feature files are read
    Then qualify-frozen-corrective-consumer: the init invalid scenario keeps its exit, provider, file and tree assertions
    And qualify-frozen-corrective-consumer: the init invalid stdout assertions accept the primary diagnostic with additive context
    And qualify-frozen-corrective-consumer: the init invalid stdout assertions reject output without the primary diagnostic

  Scenario: Missing tool scenario keeps Ruff absent and tolerates additive lines
    Given qualify-frozen-corrective-consumer: the three consumer feature files are read
    Then qualify-frozen-corrective-consumer: the missing tool scenario keeps its exit, ruff absence and zero request assertions
    And qualify-frozen-corrective-consumer: the missing tool stdout assertions accept additive check context and next-step lines
    And qualify-frozen-corrective-consumer: the missing tool stdout assertions reject a different tool or a missing stopped-startup or inspect line

  Scenario: Refine half is seeded by a real passed Shape
    Given qualify-frozen-corrective-consumer: the three consumer feature files are read
    Then qualify-frozen-corrective-consumer: the Refine half is seeded by a successful Shape through a fake provider before the malicious fixture is installed

  Scenario: Scope is preserved
    Given qualify-frozen-corrective-consumer: the three consumer feature files are read
    Then qualify-frozen-corrective-consumer: no scenario is removed or skipped and no protected or producer path is edited
