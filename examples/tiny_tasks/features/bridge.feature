Feature: Tiny Tasks CLI bridge

  @BASE-1 @BASE-2
  Scenario: Add and list tasks through the real Mix CLI
    Given an empty task list
    When I add a task "Call the dentist"
    And I add a task "Pick up a parcel"
    When I list all tasks
    Then the tasks shown are:
      """
      1 [open] Call the dentist
      2 [open] Pick up a parcel
      """
