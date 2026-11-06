Feature: The live real-use test runs end to end on the Claude Code route
  test/live/real-use.sh proves the whole new-user path on a fresh home for both routes: install the
  release, kogen init, shape, approve, build (interrupted, then landed), verify, leak check and
  uninstall. These runs are offline: the release the configured setup packaged, the py-calc fixture,
  a fake ChatGPT server on both routes and the repository's fake Claude Code served as Kogen's
  managed runtime. The login reaches the run home only through KOGEN_LIVE_CREDENTIALS.

  Scenario: With only a claude-code login, every real-use check passes and nothing reaches ChatGPT
    Given k-live-real-use-claude: a fresh real-use run whose only login is "claude-code"
    When k-live-real-use-claude: the real-use script runs on the py-calc fixture
    Then k-live-real-use-claude: the real-use script exits 0
    And k-live-real-use-claude: the transcript has these lines in order:
      | ok: kogen version works from /                                                               |
      | route: claude-code                                                                           |
      | ok: kogen provider list shows claude-code: token saved (not verified)                        |
      | ok: .kogen/models.yaml from kogen init runs shape, build and review on claude-code           |
      | ok: the managed Claude Code runtime is installed in the run home                             |
      | ok: the Intent is ready with its scenarios failing                                           |
      | ok: no new commit after the interrupt                                                        |
      | ok: at least one Claude Code round ran in the Build                                          |
      | ok: the Build landed with review: approved                                                   |
      | ok: the project's own acceptance command and tests pass without Kogen                        |
      | ok: commit subject is the Intent title                                                       |
      | ok: the only trailer is Kogen-Intent: is-even                                                |
      | ok: no AI attribution                                                                        |
      | ok: unsigned, as this host's Git configuration says                                          |
      | ok: no Kogen process is alive                                                                |
      | ok: no credential token in the project, .kogen/local, the transcript or the command outputs |
      | ok: no ChatGPT login hint in the transcript or the command outputs                           |
      | ok: kogen is gone                                                                            |
      | ok: the project and ~/.kogen are intact                                                      |
      | REL-1 passed for real-use-fixture                                                            |
    And k-live-real-use-claude: the fake ChatGPT server received no request
    And k-live-real-use-claude: no transcript or command output contains "provider login chatgpt"
    And k-live-real-use-claude: the Claude Code download origin served the runtime once
    And k-live-real-use-claude: the fake Claude Code runtime answered kogen init and then the shape, build and review roles
    And k-live-real-use-claude: the landed .kogen/models.yaml runs shape, build and review on "claude-code"
    And k-live-real-use-claude: the landed commit is "Add an is-even helper" and adds calc.is_even

  Scenario: The ChatGPT route on a fake ChatGPT server still lands a commit and reads init's lineup
    Given k-live-real-use-claude: a fresh real-use run whose only login is "chatgpt"
    When k-live-real-use-claude: the real-use script runs on the py-calc fixture
    Then k-live-real-use-claude: the real-use script exits 0
    And k-live-real-use-claude: the transcript has these lines in order:
      | ok: kogen version works from /                                                               |
      | route: chatgpt                                                                               |
      | ok: kogen provider list shows chatgpt: signed in                                             |
      | ok: .kogen/models.yaml from kogen init runs shape, build and review on chatgpt               |
      | ok: the Intent is ready with its scenarios failing                                           |
      | ok: no new commit after the interrupt                                                        |
      | ok: at least one tool call ran with the default configuration                                |
      | ok: the Build landed with review: approved                                                   |
      | ok: no credential token in the project, .kogen/local, the transcript or the command outputs |
      | ok: kogen is gone                                                                            |
      | ok: the project and ~/.kogen are intact                                                      |
      | REL-1 passed for real-use-fixture                                                            |
    And k-live-real-use-claude: the fake ChatGPT server answered init, shape, build and review requests
    And k-live-real-use-claude: the Claude Code download origin received no request
    And k-live-real-use-claude: the landed .kogen/models.yaml runs shape, build and review on "chatgpt"
    And k-live-real-use-claude: the landed commit is "Add an is-even helper" and adds calc.is_even

  Scenario Outline: The leak check fails when the claude-code token appears in the <place>
    Given k-live-real-use-claude: a fresh real-use run whose only login is "claude-code"
    And k-live-real-use-claude: the project's own checks copy the saved claude-code token into the <place>
    When k-live-real-use-claude: the real-use script runs on the py-calc fixture
    Then k-live-real-use-claude: the real-use script exits 1
    And k-live-real-use-claude: the transcript's last line is "FAIL: no credential token in the project, .kogen/local, the transcript or the command outputs"
    And k-live-real-use-claude: the leak report lists "<file>"

    Examples:
      | place      | file                            |
      | transcript | {run}/transcript.txt            |
      | project    | {run}/project/leaked-token.json |
