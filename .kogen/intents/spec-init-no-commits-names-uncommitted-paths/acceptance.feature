Feature: The init no-commits scenario accepts the producer text before and after adoption
  This feature checks the scenario "Init in a repository whose files are not committed yet asks for the first commit" of the project setup feature against the old and the new refusal line.

  Scenario: The assertion accepts the old text printed by the current vendored producer
    Given spec-init-no-commits-names-uncommitted-paths: the project setup feature is read
    Then spec-init-no-commits-names-uncommitted-paths: the scenario keeps its fixture, command and exit code 3
    And spec-init-no-commits-names-uncommitted-paths: the stdout assertions accept the old text without the path

  Scenario: The assertion accepts the new text naming app.txt
    Given spec-init-no-commits-names-uncommitted-paths: the project setup feature is read
    Then spec-init-no-commits-names-uncommitted-paths: the stdout assertions accept the new text naming the path
    And spec-init-no-commits-names-uncommitted-paths: the scenario no longer compares all of stdout exactly

  Scenario: The assertion rejects every other message
    Given spec-init-no-commits-names-uncommitted-paths: the project setup feature is read
    Then spec-init-no-commits-names-uncommitted-paths: the scenario keeps its fixture, command and exit code 3
    And spec-init-no-commits-names-uncommitted-paths: the stdout assertions reject every other message

  Scenario: Scope is preserved
    Given spec-init-no-commits-names-uncommitted-paths: the project setup feature is read
    Then spec-init-no-commits-names-uncommitted-paths: no scenario is removed or skipped and nothing else in the feature or the protected paths changes
