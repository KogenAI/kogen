Feature: Complete a Tiny Tasks item without losing the rest of the list

  Background:
    Given tiny-tasks-complete-command: I add these tasks to a fresh temporary task file in this order:
      | Pay the rent       |
      | Water the plants   |
      | Take out recycling |

  Scenario: Complete the middle open task in place
    When tiny-tasks-complete-command: I run mix todo.complete with the ID of "Water the plants"
    Then tiny-tasks-complete-command: mix todo.complete succeeds
    And tiny-tasks-complete-command: plain mix todo.list shows exactly these tasks with their original IDs in order:
      | open | Pay the rent       |
      | done | Water the plants   |
      | open | Take out recycling |
    And tiny-tasks-complete-command: only the selected task's status field changes on disk

  Scenario: Reject an unknown ID without rewriting the file
    When tiny-tasks-complete-command: I run mix todo.complete with an ID absent from the list
    Then tiny-tasks-complete-command: mix todo.complete fails and reports the offending ID
    And tiny-tasks-complete-command: the task file is unchanged and was not rewritten
