Feature: The getting-started guide works for a user without ChatGPT
  docs/getting-started.md names the ChatGPT requirement of automatic discovery, gives a configuration-first path in step 4 that
  is checked against a scripted run with only an Anthropic key, shows the real doctor lines in step 2, and the new
  anthropic-only preset is a valid version-1 configuration.

  Scenario: The guide explains the ChatGPT requirement, the Without ChatGPT path and the real doctor lines
    Given the K-ONBOARD2 guide exists
    Then the guide tells a user without ChatGPT to use the configuration-first path

  Scenario: Every kogen command of the new path parses against the CLI
    Given the K-ONBOARD2 guide exists
    When the commands of the Without ChatGPT subsection and step 3 are checked against the CLI
    Then every kogen command there is a known command with known options

  Scenario: The step 2 excerpt shows lines a real run prints outside a repository
    Given the K-ONBOARD2 guide exists
    When I run kogen doctor outside any Git repository with no stored login
    Then the step 2 excerpt of the guide occurs in the actual doctor output

  Scenario: Following the Without ChatGPT steps with only an Anthropic key initialises the project
    Given the K-ONBOARD2 guide exists
    When I follow the Without ChatGPT steps in a temporary Go repository with only an Anthropic key stored
    Then kogen init succeeds and commits the configuration as "Add Kogen configuration"
    And kogen doctor reports config and models ok
    And the init and doctor excerpts of the guide occur in the actual output

  Scenario: The anthropic-only preset is a valid version-1 configuration listed with the other presets
    Given the anthropic-only preset exists
    Then the preset gives shape and build claude-sonnet-5-5 medium and review claude-opus-5-5 medium on anthropic
    And kogen doctor accepts the preset as the configuration with an Anthropic key
    And the configuration documentation lists the preset with the other presets
