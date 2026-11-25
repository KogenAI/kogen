Feature: List only open Tiny Tasks on request

  Scenario: List open tasks without changing the plain list
    Given tiny-tasks-open-task-filter: a temporary task file contains these rows in order:
      | 7 | open | Zebra   |
      | 4 | done | Finished |
      | 9 | open | Apple   |
      | 2 | open | Mango   |
    When tiny-tasks-open-task-filter: I run "mix todo.list"
    Then tiny-tasks-open-task-filter: the plain listing is exactly:
      """
      7 [open] Zebra
      4 [done] Finished
      9 [open] Apple
      2 [open] Mango
      """
    When tiny-tasks-open-task-filter: I run "mix todo.list --open"
    Then tiny-tasks-open-task-filter: the filtered listing is exactly:
      """
      7 [open] Zebra
      9 [open] Apple
      2 [open] Mango
      """

  Scenario: List a file with no open tasks
    Given tiny-tasks-open-task-filter: a temporary task file contains these rows in order:
      | 4 | done | Finished |
    When tiny-tasks-open-task-filter: I run "mix todo.list --open"
    Then tiny-tasks-open-task-filter: the empty result is exactly:
      """
      No tasks yet.
      """
