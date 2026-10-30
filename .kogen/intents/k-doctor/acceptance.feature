Feature: kogen doctor says what is ready and how to fix what is not

  Scenario: A fresh project with several problems fails with one fix per problem and passes once they are applied
    Given a doctor fixture repository with no Git identity, no provider login and an unsupported effort
    When I run kogen doctor
    Then the doctor exits with status 1
    And the doctor output has only check lines and fix lines
    And the doctor checks appear in the order install, git, config, models, commands
    And the "install" line is "ok"
    And the "git" line is "fail"
    And the "git" fix contains "git config user.name"
    And the "git" fix contains "git config user.email"
    And the "config" line is "fail"
    And the "config" detail contains "line 11"
    And the "config" detail contains "effort \"ultra\" is not supported"
    And the "models" line is "fail"
    And the "models" fix contains "kogen provider login chatgpt"
    When I apply the fixes the doctor printed
    And I run kogen doctor
    Then the doctor exits with status 0
    And no doctor line is "fail"
    And the "commands" line is "ok"

  Scenario: A check that fails on the unchanged tree is reported with its status and the baseline-failure hint, and --quick skips it
    Given a doctor fixture repository with an identity and a ChatGPT login whose committed check "broken" runs "touch ran-marker; exit 7"
    When I run kogen doctor
    Then the doctor exits with status 1
    And the "commands" line is "fail"
    And the "commands" detail contains "broken"
    And the "commands" detail contains "status=7"
    And the "commands" detail contains "baseline failure"
    And the "commands" line mentions a duration
    And the "install" line is "ok"
    And the "git" line is "ok"
    And the "config" line is "ok"
    And the "models" line is "ok"
    And the checkout has no file named "ran-marker"
    When I run kogen doctor with "--quick"
    Then the doctor exits with status 0
    And the "commands" line is "skip"

  Scenario: A claude-code role without claude on PATH fails and names the install command
    Given a doctor fixture repository with an identity whose roles use the claude-code executor and no claude on PATH
    When I run kogen doctor with "--quick"
    Then the doctor exits with status 1
    And the "install" line is not "fail"
    And the "models" line is "fail"
    And the "models" detail contains "claude"
    And the "models" fix contains "npm install -g @anthropic-ai/claude-code"
    And the "commands" line is "skip"

  Scenario: A claude older than the qualified minimum fails and names both versions
    Given a doctor fixture repository with an identity whose roles use the claude-code executor and a claude reporting version "2.0.0"
    When I run kogen doctor with "--quick"
    Then the doctor exits with status 1
    And the "models" line is "fail"
    And the "models" detail contains "2.0.0"
    And the "models" detail contains "2.1.295"

  Scenario: --json matches the text output
    Given a doctor fixture repository with no Git identity, no provider login and an unsupported effort
    When I run kogen doctor in text and in JSON form
    Then the JSON output is an array of objects with exactly check, status, detail and fix that equals the text output

  Scenario: Doctor leaves the checkout identity unchanged even when a check writes files
    Given a doctor fixture repository with an identity and a ChatGPT login whose committed check "writer" runs "touch ran-marker; echo changed > app.txt"
    And the checkout identity is recorded
    When I run kogen doctor
    Then the doctor exits with status 0
    And the "commands" line is "ok"
    And the checkout identity is unchanged

  Scenario: kogen init ends with the quick doctor summary
    When I run kogen init in a new Git repository with a ChatGPT login
    Then the init command succeeds and its output ends with the doctor summary with the install, git, config and models lines ok and the commands line skip
