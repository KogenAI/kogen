Feature: Claude Code executor uses a stored subscription token

  Scenario: Login saves a private token without printing it and the list shows it offline
    Given a Claude Code Shape project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    When I save the Claude Code token "  sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111  " from stdin
    Then the Claude Code login succeeded and printed none of the saved token
    And the Claude Code credential file is private and holds the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    When I list the providers
    Then the provider list shows the line "claude-code: token saved (not verified)"

  Scenario: A second login replaces the token
    Given a Claude Code Shape project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    When I save the Claude Code token "sk-ant-oat01-SYNTHETIC-FIRST-TOKEN-2222" from stdin
    And I save the Claude Code token "sk-ant-oat01-SYNTHETIC-SECOND-TOKEN-3333" from stdin
    Then the Claude Code credential file is private and holds the token "sk-ant-oat01-SYNTHETIC-SECOND-TOKEN-3333"
    And the Claude Code credential file does not hold "SYNTHETIC-FIRST-TOKEN-2222"

  Scenario Outline: A token with whitespace or empty input is refused
    Given a Claude Code Shape project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    When I save Claude Code stdin text "<text>"
    Then the Claude Code login was refused with a message about the token and no credential file exists

    Examples:
      | text                                  |
      | \n                                    |
      | sk-ant-oat01-SYNTHETIC AAA\n          |
      | sk-ant-oat01-SYNTHETIC-A\nsecond\n   |

  Scenario: A stored token replaces an inherited one and every other stripped variable stays out
    Given a Claude Code Shape project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    And the caller environment exports a different CLAUDE_CODE_OAUTH_TOKEN and the other stripped variables
    When I save the Claude Code token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111" from stdin
    And I run Shape with the Claude Code executor
    Then the Claude Code run asked its Shape question
    And every Claude Code child saw the CLAUDE_CODE_OAUTH_TOKEN "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111" and none of the other stripped variables
    And no Claude Code child argv contained a token
    And no output, log, run record or file outside the credential file holds the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"

  Scenario: Without a stored token an inherited token is ignored and the run is refused as before
    Given a Claude Code Shape project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-INHERITED-TOKEN-0000"
    And the caller environment exports a different CLAUDE_CODE_OAUTH_TOKEN and the other stripped variables
    When I run Shape with the Claude Code executor
    Then the Claude Code run was refused as "executor/auth_refused"
    And no Claude Code child saw any CLAUDE_CODE_OAUTH_TOKEN
    And no Claude Code model round was started

  Scenario: A stored token the fake rejects gives auth_refused with the setup-token hint
    Given a Claude Code Shape project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-SOMETHING-ELSE-9999"
    When I save the Claude Code token "sk-ant-oat01-SYNTHETIC-REJECTED-TOKEN-4444" from stdin
    And I run Shape with the Claude Code executor
    Then the Claude Code run was refused as "executor/auth_refused"
    And the refusal tells the user to run "claude setup-token" and "kogen provider login claude-code"
    And no Claude Code model round was started
    And no output, log, run record or file outside the credential file holds the token "sk-ant-oat01-SYNTHETIC-REJECTED-TOKEN-4444"

  Scenario: The documentation explains the stored token
    When I read the Claude Code token documentation
    Then every Claude Code token document mentions "claude setup-token"
    And every Claude Code token document mentions "kogen provider login claude-code"
    And the Claude Code token document "docs/executor-contract.md" mentions "CLAUDE_CODE_OAUTH_TOKEN"
    And the Claude Code token document "docs/configuration.md" mentions "claude-code.json"
