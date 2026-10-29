Feature: Building
  The builder uses shell, read_file, view_image, write_file, finish and
  report_blocker, until verification is green and the review approves. No time or
  token limit; native shell calls are unbounded unless explicitly opted in.

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
    And request 1 offers exactly the tools "shell, read_file, view_image, write_file, finish, report_blocker"
    And request 1 contains the text of the file ".kogen/intents/is-even/acceptance.feature"
    And request 1 contains the text of the file "README.md"
    And request 1 contains "python3 -m unittest"
    And request 1 contains "features/steps/is_even_steps.js"
    And request 1 contains ".style.cfg"
    And request 1 contains "background"
    And request 1 contains the text of the file ".kogen/intents/is-even/intent.md"
    And request 1 contains "Use the narrowest test that exercises the rule"
    And request 1 contains "Source provenance: unavailable (legacy)"
    And the fake ChatGPT server received 2 requests

  @LOOP-9 @LOOP-10 @REV-2 @model:build
  Scenario: Completed builder and independent reviewer windows reset locally
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-local-windows"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stderr contains "build local reset"
    And stderr contains "review local reset"
    And stderr contains "ceiling 524288; reserve 131072"
    And request 5 contains the text of the file ".kogen/intents/is-even/intent.md"
    And request 5 contains "Local working-window reset"
    And the review request 5 contains "Local working-window reset"
    And the review request 5 contains "Source provenance: unavailable (legacy)"
    And the review request 5 contains "# Pinned complete candidate source evidence"
    And the review request 5 contains "review_delivery"
    And the review request 6 contains "review_source"

  @LOOP-7 @VER-12 @GIT-8 @model:build
  Scenario: A builder-reported protected contradiction stops without later mutations or gates
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-reports-blocker"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/build_blocked"
    And stdout contains "BUILDER-REPORTED"
    And stdout contains "kogen intent recover"
    And stdout contains "freshly approve"
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

  @LOOP-5 @LOOP-11
  Scenario: Default shell calls remain unbounded
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "sleep 2"
    When the caller runs "kogen intent build is-even"
    Then the tool result for "shell sleep 2" contains "exit status: 0"
    And the exit code is 0

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
  Scenario: Long model-facing text includes an honest omission marker within 16 KiB
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
        is-even Build {id8} stopped in startup: tool_missing; candidate: {abs:.}; evidence: {abs:.kogen/local/runs}/{id8}; index: {abs:.kogen/local/runs}/{id8}/index-at-start
        kogen intent inspect {id8} --project '{abs:.}'
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
    And request 1 offers exactly the tools "shell, read_file, view_image, write_file, finish, report_blocker"
    And the fake ChatGPT server received 2 requests

  @LOOP-1 @LOOP-6 @LOOP-10 @model:stages
  Scenario: One approved staged Intent keeps the builder until whole delivery
    Given the Intent "is-even" from fixture "is-even-staged" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And request 1 contains "Active stage 1/2"
    And request 2 contains "Active stage 2/2"
    And request 2 contains the text of the file ".kogen/intents/is-even/intent.md"
    And stderr contains "stage calculation gate passed"
    And stderr contains "stage compatibility gate passed"
    And the fake ChatGPT server received 3 requests

  # The fake claude is a Node script, not a model: it answers like Claude Code and runs the
  # PreToolUse hook command that Kogen put in the --settings file before each Write or Edit.
  @LOOP-14 @LOOP-15
  Scenario: The Claude Code executor produces the candidate and Kogen's own review and single commit land it
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-correct-first-try" is on PATH
    And the environment variable "ANTHROPIC_API_KEY" is "sk-ant-fake-not-a-key"
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the committed contents of "calc.py" contain "isinstance"
    And the fake claude ran 1 round
    And fake claude round 1 received the argument "stream-json"
    And fake claude round 1 received the argument "--session-id"
    And no fake claude round received the argument "--bare"
    And no fake claude round had the environment variable "ANTHROPIC_API_KEY"
    And the run log records 1 executor round
    And the review request contains the diff of "calc.py" against the start HEAD
    And the fake ChatGPT server received 1 request

  @LOOP-14 @LOOP-15
  Scenario: A finish claim on a red tree returns Kogen's feedback to the same Claude session
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-wrong-then-correct" is on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And HEAD has 1 new commit
    And the fake claude ran 2 rounds
    And fake claude round 2 received the argument "--resume"
    And fake claude round 2 resumed the session it started in round 1
    And fake claude round 2 received a prompt containing "Verification pass 1 is not green."
    And the run log records 2 executor rounds
    And the run log shows verification pass 1 before review 1
    And the fake ChatGPT server received 1 request

  @LOOP-15
  Scenario: The Claude Code hook refuses an Edit of a protected path and the Build still lands
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-edits-protected-then-correct" is on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And the run log shows an executor hook decision "deny" for the "Edit" tool
    And the file ".style.cfg" is unchanged
    And HEAD has 1 new commit
    And the new commit does not change ".style.cfg"

  @LOOP-14 @LOOP-15
  Scenario: A protected file changed through Bash is not prevented but is detected and nothing is committed
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-bash-writes-protected" is on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/baseline_changed"
    And stdout contains ".style.cfg"
    And the run log records 1 executor round
    And HEAD is unchanged
    And no review request was sent

  @LOOP-15
  Scenario: A credential route that is not the subscription sign-in is refused before any edit
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-api-key-auth" is on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "executor/auth_refused"
    And the fake claude emitted no tool call
    And the file "calc.py" is unchanged
    And HEAD is unchanged
    And the fake ChatGPT server received 0 requests

  @LOOP-15
  Scenario: A Claude Code older than the qualified version is unavailable before any edit
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-too-old" is on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "executor/unavailable"
    And the fake claude ran 0 rounds
    And the file "calc.py" is unchanged
    And HEAD is unchanged
    And the fake ChatGPT server received 0 requests

  @LOOP-14 @LOOP-10
  Scenario: max_rounds leaves the candidate in place and the external checkpoint cannot be resumed
    Given the project config sets "models.build" to "{executor: claude-code, model: claude-sonnet-5-5, effort: high, max_rounds: 2}"
    And the Intent "is-even" from fixture "is-even" is approved
    And a fake claude with script "claude-wrong-forever" is on PATH
    And the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "candidate/executor_round_limit"
    And stdout contains "  edited: calc.py"
    And the fake claude ran 2 rounds
    And HEAD is unchanged
    And no review request was sent
    When the caller runs "kogen intent resume {build_id}"
    Then the exit code is 1
    And stdout contains "candidate/resume_refused"
    And the fake claude ran 2 rounds
    And HEAD is unchanged
