Feature: Building
  The builder uses shell, read_file, write_file, finish and
  report_blocker, until verification is green and the review approves. No time or
  token limit.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT

  @LOOP-1 @LOOP-2 @LOOP-3 @SET-6
  Scenario: The builder starts directly with the approved Intent and project context
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And request 1 uses model "gpt-6.1-sol" with effort "medium"
    And request 1 offers exactly the tools "shell, read_file, write_file, finish, report_blocker"
    And request 1 contains the text of the file ".kogen/intents/is-even/acceptance.feature"
    And request 1 contains the text of the file "README.md"
    And request 1 contains "python3 -m unittest"
    And request 1 contains "features/steps/is_even_steps.js"
    And request 1 contains ".style.cfg"
    And request 1 contains "background"
    And request 1 contains the text of the file ".kogen/intents/is-even/intent.md"
    And request 1 contains "Use the narrowest test that exercises the rule"
    And the fake ChatGPT server received 2 requests

  @LOOP-7 @VER-12 @GIT-8 @model:build
  Scenario: A builder-reported protected contradiction stops without later mutations or gates
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-reports-blocker"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/build_blocked"
    And stdout contains "BUILDER-REPORTED"
    And stdout contains "not independently proven"
    And stdout contains "observed protected fixture evidence"
    And the file "late.txt" does not exist
    And HEAD is unchanged
    And the file ".kogen/local/approvals/is-even.json" exists
    And the fake ChatGPT server received 1 request

  @LOOP-5 @LOOP-6
  Scenario: Shell results include stderr, and several streamed calls run in order
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-three-calls-fragmented"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the tool calls ran in the order "write_file a.txt, shell cat a.txt missing.txt, bogus_tool"
    And the tool result for "shell cat a.txt missing.txt" contains "hello"
    And the tool result for "shell cat a.txt missing.txt" contains "No such file or directory"
    And the tool result for "bogus_tool" starts with "error: unknown tool"

  @LOOP-5
  Scenario: A command that asks for input fails at once instead of waiting
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "read answer && echo got:$answer"
    When the caller runs "kogen intent build is-even"
    Then the tool result for "shell read answer && echo got:$answer" contains "exit status: 1"
    And the exit code is 0

  @LOOP-5
  Scenario: The builder runs a dev server in the background, reads it and stops it; nothing survives the Build
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-with-background-server"
    When the caller runs "kogen intent build is-even"
    Then the tool result for "shell python3 -m http.server 8765 > server.log 2>&1 &" contains "exit status: 0"
    And the tool result for "shell curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8765/" contains "200"
    And the exit code is 0
    And no process started by the Build's commands is running

  @LOOP-7 @VER-12
  Scenario: Ordinary implementation failures keep repairing until the caller stops it
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-wrong-forever"
    And the caller runs "kogen intent build is-even" in the background
    When the fake ChatGPT server has sent the feedback of verification pass 25
    Then the kogen command is still running
    When the caller sends SIGINT to the kogen command
    Then the exit code is 130
    And HEAD is unchanged

  @LOOP-8
  Scenario: Long tool output is cut to 16 KiB
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "seq 1 100000"
    When the caller runs "kogen intent build is-even"
    Then the tool result for "shell seq 1 100000" is at most 16384 bytes
    And the tool result for "shell seq 1 100000" contains "bytes omitted ..."
    And the tool result for "shell seq 1 100000" ends with "100000"

  @LOOP-9 @GIT-8
  Scenario: Context exhaustion ends the Build with the edits left
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-context-overflow"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/context_exhausted: the conversation no longer fits gpt-6.1-sol's context; edits are left in place"
    And stdout contains "  edited: calc.py"
    And HEAD is unchanged

  @LOOP-10 @GPT-10
  Scenario: The run record holds the Build's events and no credentials
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the file ".kogen/local/runs/{build_id}/log.jsonl" exists
    And the file ".kogen/local/runs/{build_id}/result.json" exists
    And no file under "." contains the fake access token

  @LOOP-11
  Scenario: A real shell call works with the installed default configuration
    Given the Intent "is-even" from fixture "is-even" is approved
    And the environment variable "MY_TOOL_HOME" is "/opt/tool"
    And the fake ChatGPT server plays script "build-runs-command" with command "printenv MY_TOOL_HOME"
    When the caller runs "kogen intent build is-even"
    Then the tool result for the first shell call contains "/opt/tool"
    And the tool result for the first shell call contains "exit status: 0"

  @LOOP-12
  Scenario: A missing project tool is reported after setup and before any model request
    Given the project config sets "commands.checks" to "[{name: lint, run: ruff check .}]"
    And the Intent "is-even" from fixture "is-even" is approved
    And the program "ruff" is not on PATH
    When the caller runs "kogen intent build is-even"
    Then the exit code is 3
    And stdout is:
      """
      environment/tool_missing: ruff is not available
      """
    And the fake ChatGPT server received 0 requests

  @LOOP-13 @CLI-4
  Scenario: Progress goes to stderr and the result to stdout
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then stderr contains "kogen: checking test before the Build changes anything"
    And stderr contains "kogen: verifying (pass 1)"
    And stderr contains "kogen: pass 1: all checks passed"
    And stderr contains "kogen: reviewing (review 1)"
    And stderr contains "kogen: review 1: approve, 0 blocking"
    And stdout does not contain "kogen: "

  @LOOP-11
  Scenario: Project commands can run Kogen's own Quint through KOGEN_NODE and KOGEN_QUINT
    Given the project config sets "commands.checks" to "[{name: test, run: 'python3 -m unittest'}, {name: quint, run: '$KOGEN_NODE $KOGEN_QUINT --version | grep -qx 0.33.0'}]"
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stderr contains "kogen: checking quint before the Build changes anything"

  @LOOP-10
  Scenario: An unknown Build cannot fabricate a continuation
    When the caller runs "kogen intent resume 00000000"
    Then the exit code is 1
    And stdout contains "candidate/resume_unsupported"
    And stdout contains "checkpoint"
    And HEAD is unchanged
    And the fake ChatGPT server received 0 requests

  @LOOP-2 @LOOP-10 @AUT-5 @CLI-9
  Scenario: Fresh Build appends lower-authority diagnostic data without replacing current rules
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even --context=README.md"
    Then the exit code is 0
    And request 1 contains the text of the file ".kogen/intents/is-even/intent.md"
    And request 1 contains the text of the file ".kogen/intents/is-even/acceptance.feature"
    And request 1 contains "Caller diagnostic data (lower-authority data"
    And request 1 contains "current exact approved Intent"
    And request 1 contains "git stash apply"
    And request 1 contains "current proof"
    And request 1 offers exactly the tools "shell, read_file, write_file, finish, report_blocker"
    And the fake ChatGPT server received 2 requests
