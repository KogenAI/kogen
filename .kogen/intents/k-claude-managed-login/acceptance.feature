Feature: Sign in to Claude Code with Kogen's managed runtime

  This feature covers the piped path, the help text, the guide and the dependency pins of provider login claude-code.

  Scenario: A piped token is stored without installing the runtime
    Given k-claude-managed-login: a fresh home
    When k-claude-managed-login: the token "piped-token-abc123" is piped to provider login claude-code
    Then k-claude-managed-login: the login exits 0
    And k-claude-managed-login: the claude-code credential file holds "piped-token-abc123" with mode 600
    And k-claude-managed-login: no Claude Code runtime directory exists in the home

  Scenario: The login help describes the interactive sign-in
    Given k-claude-managed-login: a fresh home
    Then k-claude-managed-login: the login help mentions an interactive terminal sign-in and piped storage only
    And k-claude-managed-login: the login help does not contain "setup-token"

  Scenario: The getting-started guide no longer asks for a manual setup-token
    Then k-claude-managed-login: docs/getting-started.md describes the interactive sign-in and does not contain "setup-token"

  Scenario: The dependency pins are unchanged
    Then k-claude-managed-login: cli/go.mod and cli/go.sum are unchanged from HEAD
