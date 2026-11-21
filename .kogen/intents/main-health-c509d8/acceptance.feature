Feature: The provider help page printed by usage errors matches chapter 09

  This feature runs the built kogen binary for the two provider usage errors of chapter 09 and compares the printed page with chapter 09 and with the page the acceptance harness expects.

  Scenario: Usage error for an unknown provider prints the chapter 09 provider page
    Given main-health-c509d8: the kogen binary is built from the cli folder
    When main-health-c509d8: the caller runs "kogen provider login grok"
    Then main-health-c509d8: the exit code is 2
    And main-health-c509d8: the first line of stdout is "kogen provider login: unknown provider 'grok' (supported: chatgpt, supergrok, opencode-go, anthropic, claude-code, openai-compatible)"
    And main-health-c509d8: the rest of stdout after a blank line is the provider page given in chapter 09
    And main-health-c509d8: the rest of stdout after a blank line is the provider page the acceptance harness expects
    And main-health-c509d8: the printed provider page carries the login line

  Scenario: Usage error for an unknown option prints the chapter 09 provider page
    Given main-health-c509d8: the kogen binary is built from the cli folder
    When main-health-c509d8: the caller runs "kogen provider login openai-compatible --base-url https://a.example/v1"
    Then main-health-c509d8: the exit code is 2
    And main-health-c509d8: the first line of stdout is "kogen provider login: unknown option '--base-url'"
    And main-health-c509d8: the rest of stdout after a blank line is the provider page given in chapter 09
    And main-health-c509d8: the rest of stdout after a blank line is the provider page the acceptance harness expects
    And main-health-c509d8: the printed provider page carries the login line
