Feature: A stored Claude Code token reaches the child on file descriptor 3

  Scenario: The stored token is on fd 3 in every child and no token or scrub variable is in the env
    Given a Claude Code fd 3 project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    When I save the fd 3 Claude Code token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111" from stdin
    And I run Shape with the Claude Code executor for the fd 3 project
    Then every Claude Code child got the stored token on fd 3 and only the FILE_DESCRIPTOR variable, in the first round and in a --resume round
    And no output, log, run record or file outside the credential file holds the fd 3 token

  Scenario: Inherited credential variables are not passed through next to a stored token
    Given a Claude Code fd 3 project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111"
    And the caller environment exports inherited Claude Code credential variables including both FILE_DESCRIPTOR variables
    When I save the fd 3 Claude Code token "sk-ant-oat01-SYNTHETIC-STORED-TOKEN-1111" from stdin
    And I run Shape with the Claude Code executor for the fd 3 project
    Then every Claude Code child got the stored token on fd 3 and only the FILE_DESCRIPTOR variable, in the first round and in a --resume round

  Scenario: Without a stored token the child has no fd 3 and no FILE_DESCRIPTOR variable
    Given a Claude Code fd 3 project whose fake claude accepts the token "sk-ant-oat01-SYNTHETIC-INHERITED-TOKEN-0000"
    And the caller environment exports inherited Claude Code credential variables including both FILE_DESCRIPTOR variables
    When I run Shape with the Claude Code executor for the fd 3 project
    Then the fd 3 Claude Code run was refused as "executor/auth_refused"
    And no Claude Code child had fd 3 or any credential variable
    And no Claude Code model round was started in the fd 3 project
