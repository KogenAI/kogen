Feature: Unsupported efforts are rejected when the configuration is read

  Scenario: ultra for a native Anthropic role fails at load with the line and the accepted list
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      commands:
        setup: ['touch SETUP_RAN']
      models:
        build:
          provider: anthropic
          model: claude-opus-5-5
          effort: ultra
      """
    When I run kogen intent build for an Intent named abc
    Then the command exits with status 3
    And the output contains "environment/project_config_invalid"
    And the output contains "line 8: models.build.effort \"ultra\" is not supported"
    And the output contains "accepted: low, medium, high, xhigh, max"
    And the project has no file named "SETUP_RAN"

  Scenario: a claude-code role with an effort the CLI does not accept fails the same way
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      commands:
        setup: ['touch SETUP_RAN']
      models:
        build:
          executor: claude-code
          model: claude-sonnet-5-5
          effort: turbo
      """
    When I run kogen intent build for an Intent named abc
    Then the command exits with status 3
    And the output contains "line 8: models.build.effort \"turbo\" is not supported"
    And the output contains "accepted: low, medium, high, xhigh, max"
    And the project has no file named "SETUP_RAN"

  Scenario: ultra for a claude-code role is rejected
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      models:
        review: {executor: claude-code, model: claude-opus-5-5, effort: ultra}
      """
    When I run kogen intent build for an Intent named abc
    Then the command exits with status 3
    And the output contains "line 3: models.review.effort \"ultra\" is not supported"

  Scenario: an unsupported SuperGrok effort lists the SuperGrok efforts
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      models:
        shape: {provider: supergrok, model: grok-4.7, effort: max}
      """
    When I run kogen intent build for an Intent named abc
    Then the command exits with status 3
    And the output contains "line 3: models.shape.effort \"max\" is not supported"
    And the output contains "accepted: low, medium, high, xhigh"

  Scenario: ultra is rejected on routes that have no known effort list, including a shape worker
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      models:
        build: {model: gpt-6.1-sol, effort: ultra}
        review: {provider: opencode-go, model: kimi-k3, effort: ultra}
      shape_workers:
        enabled: false
        read: {provider: openai-compatible, model: m, effort: ultra, base_url: 'http://localhost:11434/v1'}
      """
    When I run kogen intent build for an Intent named abc
    Then the command exits with status 3
    And the output contains "line 3: models.build.effort \"ultra\" is not supported"
    And the output contains "line 4: models.review.effort \"ultra\" is not supported"
    And the output contains "line 7: shape_workers.read.effort \"ultra\" is not supported"

  Scenario: a route with no known list still passes any other effort through
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      models:
        build: {model: gpt-6.1-sol, effort: whatever}
        review: {provider: opencode-go, model: kimi-k3, effort: xhigh}
        shape: {provider: openai-compatible, model: m, effort: default, base_url: 'http://localhost:11434/v1'}
      """
    When I run kogen intent build for an Intent named abc
    Then the output does not contain "project_config_invalid"

  Scenario: every documented effort of a known route still loads
    Given a scratch Kogen project whose project.yaml is:
      """
      version: 1
      models:
        shape: {provider: anthropic, model: claude-opus-5-5, effort: max}
        build: {provider: supergrok, model: grok-4.7, effort: xhigh}
        review: {executor: claude-code, model: claude-opus-5-5, effort: xhigh}
      """
    When I run kogen intent build for an Intent named abc
    Then the output does not contain "project_config_invalid"

  Scenario: Kogen's own configuration still loads
    Given a scratch Kogen project with the repository's own project configuration
    When I run kogen intent build for an Intent named abc
    Then the output does not contain "project_config_invalid"

  Scenario: the configuration examples of the configuration guide raise no effort problem
    Given a scratch Kogen project with the repository's own project configuration
    When I load every models or shape_workers example of the configuration guide
    Then the output reports no problem about an effort
