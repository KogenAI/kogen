Feature: Account-first provider login
  This feature covers `kogen provider login` with no argument: it asks which account to use, guides a QwenCloud login with a lineup preview, and leaves the direct form unchanged.

  Scenario: A terminal login asks the account question with the seven choices
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I run kogen provider login on a simulated terminal and stop at the choices
    Then onboarding-account-first: the question and the seven choices appear in order

  Scenario: Non-interactive input is refused with usage and no prompt while a terminal is asked
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I run kogen provider login on a simulated terminal and stop at the choices
    And onboarding-account-first: I run kogen provider login with piped empty input
    Then onboarding-account-first: the terminal run asked the question and the piped run exited 2 with usage text and no prompt

  Scenario: QwenCloud Token Plan shows the warning and the preview, then saves after confirmation
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I choose QwenCloud then "Token Plan" with the fake key and answer "y" to the confirmation
    Then onboarding-account-first: the Token Plan automation warning is printed exactly once
    And onboarding-account-first: the experimental label is printed
    And onboarding-account-first: the lineup preview names "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1" with qwen4-max and effort high before the confirmation prompt
    And onboarding-account-first: the key never appears in the output
    And onboarding-account-first: an openai-compatible login bound to "https://token-plan.maas.qwencloudapi.com" is saved
    And onboarding-account-first: models.yaml has the build role "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1", qwen4-max, effort high and the same shape and review

  Scenario: QwenCloud pay-as-you-go shows the Singapore base URL and no warning
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I choose QwenCloud then "Pay-as-you-go" with the fake key and answer "y" to the confirmation
    Then onboarding-account-first: no automation warning is printed
    And onboarding-account-first: the lineup preview names "https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1" with qwen4-max and effort high before the confirmation prompt
    And onboarding-account-first: an openai-compatible login bound to "https://ap-southeast-1.maas.qwencloudapi.com" is saved
    And onboarding-account-first: models.yaml has the build role "https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1", qwen4-max, effort high and the same shape and review

  Scenario: Declining the confirmation saves nothing
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I choose QwenCloud then "Token Plan" with the fake key and answer "n" to the confirmation
    Then onboarding-account-first: no credential file exists and models.yaml is unchanged
    And onboarding-account-first: the key never appears in the output

  Scenario: Advanced setup offers Chat Completions and then the existing prompts
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I choose Advanced setup then Chat Completions with a base URL and the fake key
    Then onboarding-account-first: the Base URL and API key prompts appear and only Chat Completions is offered
    And onboarding-account-first: an openai-compatible login bound to "https://example.com" is saved
    And onboarding-account-first: the key never appears in the output

  Scenario: The direct form keeps working for scripts
    Given onboarding-account-first: a project with a lineup file and an empty home
    When onboarding-account-first: I run kogen provider login openai-compatible with a piped base URL and key
    Then onboarding-account-first: the run exits 0, prompts for the base URL and key without a menu, and saves the login for "https://example.com"
    And onboarding-account-first: models.yaml is unchanged

  Scenario: The getting-started guide starts with the same question
    Then onboarding-account-first: the getting-started provider section starts with the question and the seven choices in order
