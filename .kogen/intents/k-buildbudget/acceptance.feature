Feature: Total builder request budget
  Scenario Outline: Exercise the real Build budget contracts
    When the Build budget contract test "<test>" runs
    Then the Build budget contract test passes with a recorded execution
    Examples:
      | test |
      | TestBuildRequestBudgetAcrossPasses |
      | TestBuildRequestBudgetResume |
      | TestBuildRequestBudgetOff |
      | TestBuildRequestBudgetReview |
