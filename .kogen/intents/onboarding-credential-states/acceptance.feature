Feature: Credential states in the CLI
  This feature covers `kogen provider test` and `kogen provider list`: key saved, connection tested and role verified are three separate states, with the same labels in the CLI and in docs/providers.md. Every fixture server is local and no model is used.

  Scenario: A passing connection test shows key saved and connection tested, never role verified
    Given onboarding-credential-states: a fixture OpenAI-compatible server that answers every chat request with a completion
    And onboarding-credential-states: a project whose QwenCloud build role uses the fixture, with a saved fake key
    When onboarding-credential-states: I run kogen provider test openai-compatible
    Then onboarding-credential-states: the command succeeds and prints connection tested with a time
    And onboarding-credential-states: the fixture received exactly one minimal streaming request carrying the fake key and no tools
    And onboarding-credential-states: the result is recorded outside the project and the project files are unchanged
    When onboarding-credential-states: I run kogen provider list
    Then onboarding-credential-states: the openai-compatible provider shows key saved and connection tested
    And onboarding-credential-states: the build role shows key saved and connection tested but not role verified
    And onboarding-credential-states: the fake key appears nowhere in the output

  Scenario: A rejected key shows the auth class and drops connection tested
    Given onboarding-credential-states: a fixture OpenAI-compatible server that answers every chat request with a completion
    And onboarding-credential-states: a project whose QwenCloud build role uses the fixture, with a saved fake key
    When onboarding-credential-states: I run kogen provider test openai-compatible
    Then onboarding-credential-states: the command succeeds and prints connection tested with a time
    Given onboarding-credential-states: the fixture now answers every request with HTTP 401 and a body that echoes the key
    When onboarding-credential-states: I run kogen provider test openai-compatible
    Then onboarding-credential-states: the command fails and prints the auth failure class
    And onboarding-credential-states: the fake key appears nowhere in the output
    When onboarding-credential-states: I run kogen provider list
    Then onboarding-credential-states: the openai-compatible provider shows key saved but not connection tested
    And onboarding-credential-states: the build role shows key saved but not connection tested
    And onboarding-credential-states: the fake key appears nowhere in the output

  Scenario: A first byte that never arrives shows the timeout class
    Given onboarding-credential-states: a fixture OpenAI-compatible server that never sends its first byte
    And onboarding-credential-states: a project whose QwenCloud build role uses the fixture, with a saved fake key
    When onboarding-credential-states: I run kogen provider test openai-compatible
    Then onboarding-credential-states: the command ends by itself while the fixture still withholds its first byte, fails and prints the timeout failure class
    And onboarding-credential-states: the fake key appears nowhere in the output

  Scenario: The three labels in the CLI are the labels docs/providers.md defines
    Given onboarding-credential-states: a fixture OpenAI-compatible server that answers every chat request with a completion
    And onboarding-credential-states: a project whose QwenCloud build role uses the fixture, with a saved fake key
    When onboarding-credential-states: I run kogen provider test openai-compatible
    And onboarding-credential-states: I run kogen provider list
    Then onboarding-credential-states: the CLI output contains the three labels key saved, connection tested and role verified exactly
    And onboarding-credential-states: the labels defined in the state labels section of docs/providers.md are identical to the labels printed by the CLI
    And onboarding-credential-states: each definition in docs/providers.md is one sentence
