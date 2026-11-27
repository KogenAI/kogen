Feature: Task store reports a malformed row
  This feature checks that a malformed row in the task file stops the command with an error naming the file and the one-based line, and leaves the file untouched.

  Scenario: A row with too few fields is rejected with its location
    Given task-store-reports-malformed-row: a task file whose contents are "1\topen\tWmVicmE=\n2\topen\n"
    When task-store-reports-malformed-row: I run "todo.list" on that task file
    Then task-store-reports-malformed-row: the command exits unsuccessfully
    And task-store-reports-malformed-row: the output names the task file path and line 2
    And task-store-reports-malformed-row: the output reports no raw exception
    And task-store-reports-malformed-row: the task file is byte-for-byte unchanged

  Scenario: A row after a blank line is reported with its file line number
    Given task-store-reports-malformed-row: a task file whose contents are "1\topen\tWmVicmE=\n\n2\topen\tQXBwbGU=\textra\n"
    When task-store-reports-malformed-row: I run "todo.list" on that task file
    Then task-store-reports-malformed-row: the command exits unsuccessfully
    And task-store-reports-malformed-row: the output names the task file path and line 3
    And task-store-reports-malformed-row: the output reports no raw exception
    And task-store-reports-malformed-row: the task file is byte-for-byte unchanged

  Scenario: A nonnumeric ID is rejected with its location
    Given task-store-reports-malformed-row: a task file whose contents are "abc\topen\tWmVicmE=\n"
    When task-store-reports-malformed-row: I run "todo.list" on that task file
    Then task-store-reports-malformed-row: the command exits unsuccessfully
    And task-store-reports-malformed-row: the output names the task file path and line 1
    And task-store-reports-malformed-row: the output reports no raw exception
    And task-store-reports-malformed-row: the task file is byte-for-byte unchanged

  Scenario: An ID with a numeric prefix is rejected with its location
    Given task-store-reports-malformed-row: a task file whose contents are "1\topen\tWmVicmE=\n2x\topen\tQXBwbGU=\n"
    When task-store-reports-malformed-row: I run "todo.list" on that task file
    Then task-store-reports-malformed-row: the command exits unsuccessfully
    And task-store-reports-malformed-row: the output names the task file path and line 2
    And task-store-reports-malformed-row: the output reports no raw exception
    And task-store-reports-malformed-row: the task file is byte-for-byte unchanged

  Scenario: A valid task file lists tasks in stored order
    Given task-store-reports-malformed-row: a task file whose contents are "7\topen\tWmVicmE=\n4\tdone\tRmluaXNoZWQ=\n9\topen\tQXBwbGU=\n2\topen\tTWFuZ28=\n"
    When task-store-reports-malformed-row: I run "todo.list" on that task file
    Then task-store-reports-malformed-row: the command exits successfully
    And task-store-reports-malformed-row: the listed tasks are exactly, in order:
      | 7 [open] Zebra |
      | 4 [done] Finished |
      | 9 [open] Apple |
      | 2 [open] Mango |
    And task-store-reports-malformed-row: the task file is byte-for-byte unchanged
