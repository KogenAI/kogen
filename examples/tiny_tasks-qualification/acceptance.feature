Feature: Complete a task while preserving the task list

  @TASK-1 @TASK-2
  Scenario: Completing one task preserves every task and filters open work
    Given an empty task list
    When I add a task "Review invoices"
    And I add a task "Book the dentist"
    And I add a task "Water the plants"
    And I complete task 2
    When I list open tasks
    Then the tasks shown are:
      """
      1 [open] Review invoices
      3 [open] Water the plants
      """
    When I list all tasks
    Then the tasks shown are:
      """
      1 [open] Review invoices
      2 [done] Book the dentist
      3 [open] Water the plants
      """
