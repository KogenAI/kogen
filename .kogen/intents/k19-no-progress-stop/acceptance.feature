Feature: An external Build that makes no progress stops before the round cap

  Scenario: Three identical red passes after builder rounds stop the Build
    When the k19 fake external builder finishes without edits against the same red check in the case "identical"
    Then the k19 Build recorded one executor_no_progress event and stopped with candidate executor_round_limit after the third identical pass, before the round cap

  Scenario: A failing set that changes every round does not stop the Build early
    When the k19 fake external builder finishes without edits against the same red check in the case "changing"
    Then the k19 Build was not stopped early and ran to its round cap without an executor_no_progress event

  Scenario: A green pass resets the count
    When the k19 fake external builder meets a green pass between identical red passes in the case "green-reset"
    Then the k19 Build counted again from one after the green pass and stopped on the third identical red pass after it
