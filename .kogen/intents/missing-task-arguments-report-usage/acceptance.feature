Feature: Missing task arguments report usage
  This feature checks that the Tiny Tasks commands todo.add and todo.complete report which required argument is missing.

  Scenario: todo.add without a title reports a usage error
    Given missing-task-arguments-report-usage: there is no task file yet
    When missing-task-arguments-report-usage: I run "todo.add" with no arguments
    Then missing-task-arguments-report-usage: the command exits unsuccessfully
    And missing-task-arguments-report-usage: the output names the missing "title"
    And missing-task-arguments-report-usage: the output reports no function clause error
    And missing-task-arguments-report-usage: no task file exists

  Scenario: todo.complete without an ID reports a usage error and keeps the file
    Given missing-task-arguments-report-usage: a task file holding the task "Pay the rent"
    When missing-task-arguments-report-usage: I run "todo.complete" with no arguments
    Then missing-task-arguments-report-usage: the command exits unsuccessfully
    And missing-task-arguments-report-usage: the output names the missing "ID"
    And missing-task-arguments-report-usage: the output reports no function clause error
    And missing-task-arguments-report-usage: the task file is byte-for-byte unchanged
