Feature: Refuse empty usage record filters

  Background:
    Given usage-empty-filter-values-refuse: a project with retained requests in phases "review,Review,reviewer"

  Scenario: Reject an empty phase in equals form
    When usage-empty-filter-values-refuse: kogen intent usage runs with these extra arguments
      """
      ["--phase="]
      """
    Then usage-empty-filter-values-refuse: the usage error names "--phase" as empty

  Scenario: Reject an empty model in a separate argument
    When usage-empty-filter-values-refuse: kogen intent usage runs with these extra arguments
      """
      ["--model", ""]
      """
    Then usage-empty-filter-values-refuse: the usage error names "--model" as empty

  Scenario: Keep exact matching for a nonempty phase
    When usage-empty-filter-values-refuse: kogen intent usage runs with these extra arguments
      """
      []
      """
    Then usage-empty-filter-values-refuse: the report lists exactly these request phases in order "review,Review,reviewer"
    When usage-empty-filter-values-refuse: kogen intent usage runs with these extra arguments
      """
      ["--phase=review"]
      """
    Then usage-empty-filter-values-refuse: the report lists exactly these request phases in order "review"
