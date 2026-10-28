Feature: A Decision can cover an undefined audit defect

  Background:
    When the k25b coverage rule judges its fixed defects

  Scenario: A Decision line that defines the missing name covers an undefined defect
    Then the k25b "defined" cases are judged as specified

  Scenario: A mention without a definition, or a definition of another name, does not cover it
    Then the k25b "mention" cases are judged as specified

  Scenario: A question with both quotes still covers an undefined defect
    Then the k25b "question" cases are judged as specified

  Scenario: An empty result never blocks a Decision on a conflict or precedence defect
    Then the k25b "empty" cases are judged as specified

  Scenario: The conflict rule with both results stays as it was
    Then the k25b "kept" cases are judged as specified
