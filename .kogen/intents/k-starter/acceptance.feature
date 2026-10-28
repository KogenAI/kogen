Feature: kogen starter creates a reproducible starter project with a supplied request

  Scenario: A new starter project has one commit, a clean tree and the five next commands
    Given a starter workspace with a Git identity
    When I run kogen starter on "project"
    Then the starter exits with status 0
    And the starter output is exactly the five next commands for "project"
    And the starter project contains its library, tests, request, README and configuration
    And the starter project configuration names the test check and the bundled Cucumber
    And the starter repository has one commit by the identity, a clean tree and no Git settings written

  Scenario: Doctor in the starter reports config ok and the login to make
    Given a starter workspace with a Git identity
    When I run kogen starter on "project"
    And I run the quick doctor in the starter project
    Then the starter doctor exits with status 1
    And the starter doctor line "config" is "ok"
    And the starter doctor line "models" is "fail"
    And the starter doctor line "models" has a fix containing "kogen provider login chatgpt"
    When I save a synthetic ChatGPT login for the starter workspace
    And I run the quick doctor in the starter project
    Then the starter doctor exits with status 0
    And the starter doctor line "models" is "ok"
    And the starter doctor line "commands" is "skip"

  Scenario: The starter's own checks pass on the committed tree as Build startup would run them
    Given a starter workspace with a Git identity
    When I run kogen starter on "project"
    And I save a synthetic ChatGPT login for the starter workspace
    And I run the full doctor in the starter project
    Then the starter doctor exits with status 0
    And the starter doctor line "commands" is "ok"
    And the starter doctor line "commands" has detail containing "test status=0"
    And the starter doctor line "commands" has detail containing "acceptance runner reachable"
    And no starter doctor line failed

  Scenario: A non-empty target directory is refused and left unchanged
    Given a starter workspace with a Git identity
    And a non-empty starter target "busy"
    When I run kogen starter on "busy"
    Then the starter exits with status 3
    And the starter output contains "not empty"
    And the starter target is unchanged and has no Git repository

  Scenario: An existing empty directory is accepted
    Given a starter workspace with a Git identity
    And an empty starter target "empty"
    When I run kogen starter on "empty"
    Then the starter exits with status 0
    And the starter repository has one commit by the identity, a clean tree and no Git settings written

  Scenario: A missing Git identity is refused before anything is written
    Given a starter workspace without a Git identity
    When I run kogen starter on "project"
    Then the starter exits with status 3
    And the starter output contains "git_identity_missing"
    And the starter output contains "run git config user.name \"<name>\" and git config user.email \"<email>\" (global or repository)"
    And the starter target does not exist

  Scenario: A missing Git identity leaves an existing empty directory empty
    Given a starter workspace without a Git identity
    And an empty starter target "empty"
    When I run kogen starter on "empty"
    Then the starter exits with status 3
    And the starter output contains "git_identity_missing"
    And the starter target is unchanged and has no Git repository

  Scenario: The request's examples and rules agree
    Given a starter workspace with a Git identity
    When I run kogen starter on "project"
    Then the starter request has exactly the three examples and the two rules
    And a reference slugify reproduces every example and wrong variants contradict an example

  Scenario: The README states the commands and the known result
    Given a starter workspace with a Git identity
    When I run kogen starter on "project"
    Then the starter README states the commands and the known result

  Scenario: Shaping the supplied request in the starter reaches an approvable Intent
    Given a starter workspace with a Git identity
    When I run kogen starter on "project"
    And I save a synthetic ChatGPT login for the starter workspace
    And I shape slugify from request.md in the starter with a scripted provider
    Then the shaped slugify Intent is ready, can be approved by its hash and the starter still has one commit
