Feature: The Providers guide documents every provider and cannot drift from the CLI
  This feature checks docs/providers.md, its links from README.md and docs/configuration.md, and its copy into the release archive. It needs no model and no network.

  Scenario: Every provider that kogen provider login accepts has a row in the comparison table
    Given provider-catalog-docs: the accepted provider names are read from the CLI source
    Then provider-catalog-docs: the accepted names are these
      | chatgpt           |
      | supergrok         |
      | opencode-go       |
      | anthropic         |
      | claude-code       |
      | openai-compatible |
    And provider-catalog-docs: the Providers guide table has the five required columns
    And provider-catalog-docs: the Providers guide table has a row for every accepted name
    And provider-catalog-docs: every row links to its setup instructions

  Scenario: A role is verified only when its row names a qualification record that exists
    Then provider-catalog-docs: every role marked verified in the Providers guide names an existing record
    And provider-catalog-docs: the Providers guide marks exactly these roles verified
      | chatgpt   | Shape  |
      | chatgpt   | Build  |
      | chatgpt   | Review |
      | anthropic | Review |
    And provider-catalog-docs: the QwenCloud section does not call Shape or Review verified

  Scenario: The role check rejects a verified role whose record path is missing and accepts an existing one
    Then provider-catalog-docs: the role check rejects this table
      """
      | Provider | Account or key needed | Roles verified | Built in or custom endpoint | Setup |
      | --- | --- | --- | --- | --- |
      | `chatgpt` | account | Shape: verified (`spec/reference/no-such-record.md`); Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md) |
      """
    And provider-catalog-docs: the role check accepts this table
      """
      | Provider | Account or key needed | Roles verified | Built in or custom endpoint | Setup |
      | --- | --- | --- | --- | --- |
      | `chatgpt` | account | Shape: verified (`spec/reference/model-family-qualification.md`); Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md) |
      """

  Scenario: The QwenCloud section carries its label, both base URLs, the setup and the honesty note
    Then provider-catalog-docs: the QwenCloud section carries the exact label
    And provider-catalog-docs: the Providers guide contains the text 'https://token-plan.maas.qwencloudapi.com/compatible-mode/v1'
    And provider-catalog-docs: the Providers guide contains the text 'https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1'
    And provider-catalog-docs: the Providers guide contains the text 'kogen provider login openai-compatible'
    And provider-catalog-docs: the Providers guide contains the text 'build: {provider: openai-compatible, base_url: https://token-plan.maas.qwencloudapi.com/compatible-mode/v1, model: qwen4-max, effort: high}'
    And provider-catalog-docs: the QwenCloud section names Token Plan terms and pay-as-you-go in one sentence
    And provider-catalog-docs: the QwenCloud section says the Chat Completions route does not yet stream and names the 45 second first-byte watchdog
    And provider-catalog-docs: the Providers guide does not mention messages-compatible
    And provider-catalog-docs: the Providers guide uses no emoji and no unqualified works or supported claim

  Scenario: README.md and docs/configuration.md each link to the Providers guide
    Then provider-catalog-docs: README.md links to the Providers guide
    And provider-catalog-docs: docs/configuration.md links to the Providers guide
    And provider-catalog-docs: docs/configuration.md names claude-code and QwenCloud

  Scenario: The packaging script ships the Providers guide in the archive docs folder
    Then provider-catalog-docs: the packaging script copies the Providers guide into the archive docs folder

  Scenario: A Go test in the cli package guards the Providers guide
    Then provider-catalog-docs: a Go test in the cli package reads the Providers guide and the CLI source
