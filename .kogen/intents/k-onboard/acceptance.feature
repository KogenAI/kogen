Feature: The getting-started guide takes a developer from install to a landed feature
  docs/getting-started.md is checked against the real CLI: its commands parse, its output excerpts occur in a real
  scripted run, and the two doctor fix texts it explains are printed.

  Scenario: The guide has the nine steps in order and the README links to it
    Given the onboarding guide exists
    Then the guide has the nine step headings in order
    And the guide explains the install, doctor and recovery facts it must cover
    And the README Getting started section links to the guide

  Scenario: Every kogen command in the guide parses against the CLI command table
    Given the onboarding guide exists
    When the onboarding guide commands are checked against the CLI command table
    Then every kogen command in the guide is a known command with known options
    And the guide shows the commands of all nine steps

  Scenario: Every output excerpt in the guide occurs in a real scripted run
    Given the onboarding guide exists
    When I run the onboarding journey with the fake provider in a temporary repository
    Then every output excerpt in the guide occurs in the actual output of its step

  Scenario: Doctor outside a Git repository prints the new fix texts
    When I run kogen doctor from a directory outside any Git repository
    Then the onboarding doctor "git" line fails with the fix "run this inside your project's repository (cd <repo>), or git init to start a new one"
    And the onboarding doctor "config" line fails with the fix "in your project, run kogen init"

  Scenario: Doctor in a repository without project configuration prints the new config fix
    When I run kogen doctor in a Git repository that has no project configuration
    Then the onboarding doctor "git" line is "ok"
    And the onboarding doctor "config" line fails with the fix "in your project, run kogen init"
