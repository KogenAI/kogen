Feature: todo.complete refuses nonnumeric task IDs
  This feature covers how the todo.complete Mix task refuses IDs that cannot name a task.

  Scenario: A nonnumeric ID is refused as invalid
    Given complete-rejects-nonnumeric-id: a task file holding the open tasks "Pay the rent" and "Water the plants" with an old modification time
    When complete-rejects-nonnumeric-id: I run todo.complete with the ID "abc"
    Then complete-rejects-nonnumeric-id: the command exits unsuccessfully
    And complete-rejects-nonnumeric-id: the output shows no implementation exception
    And complete-rejects-nonnumeric-id: the output reports "abc" as an invalid task ID
    And complete-rejects-nonnumeric-id: the task file bytes and modification time are unchanged

  Scenario: An ID with a numeric prefix is refused as invalid
    Given complete-rejects-nonnumeric-id: a task file holding the open tasks "Pay the rent" and "Water the plants" with an old modification time
    When complete-rejects-nonnumeric-id: I run todo.complete with the ID "2x"
    Then complete-rejects-nonnumeric-id: the command exits unsuccessfully
    And complete-rejects-nonnumeric-id: the output reports "2x" as an invalid task ID
    And complete-rejects-nonnumeric-id: the task file bytes and modification time are unchanged

  Scenario: An unknown numeric ID is still reported as not found
    Given complete-rejects-nonnumeric-id: a task file holding the open tasks "Pay the rent" and "Water the plants" with an old modification time
    When complete-rejects-nonnumeric-id: I run todo.complete with the ID "99"
    Then complete-rejects-nonnumeric-id: the command exits unsuccessfully
    And complete-rejects-nonnumeric-id: the output reports that task "99" was not found
    And complete-rejects-nonnumeric-id: the task file bytes and modification time are unchanged
