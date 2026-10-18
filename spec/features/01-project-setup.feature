Feature: Project setup
  kogen init configures the project itself and commits the configuration with the user's own Git setup.

  Background:
    Given a clean Kogen home
    And the installed kogen command

  @SET-1 @SET-2 @SET-10 @SET-13 @GPT-5
  Scenario: Init configures a project without checks or runner, adds the bridge and commits once
    Given a Git project from fixture "notes"
    And the file "notes.txt" is changed outside Kogen
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-proposes-nothing"
    When the caller runs "kogen init" in the folder "docs"
    Then the exit code is 0
    And stdout is:
      """
      Initialized Kogen in {abs:.}
      Setup: none
      Checks: none found
      Acceptance: Cucumber bridge added in features/steps
      Note: Kogen gives its models README.md only; it does not read CLAUDE.md
      Commit: {sha8} Add Kogen configuration
      Next: add the project's checks to commands.checks in .kogen/project.yaml
      """
    And the new commit changes exactly:
      | path                     |
      | .gitignore               |
      | .kogen/project.yaml      |
      | features/steps/README.md |
    And the file ".gitignore" contains ".kogen/local/"
    And the file ".kogen/project.yaml" contains "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js"
    And the path "notes.txt" has uncommitted changes
    And request 1 uses model "gpt-6.1-sol" with effort "high"

  @SET-10 @SET-12 @SET-13
  Scenario: Init configures an Elixir project and leaves out a check that fails on the committed tree
    Given a Git project from fixture "ex-app"
    And the file "lib/ex_app.ex" is changed outside Kogen
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-proposes-nothing"
    When the caller runs "kogen init"
    Then the exit code is 0
    And stdout is:
      """
      Initialized Kogen in {abs:.}
      Setup: mix deps.get
      Checks: format, test
      Left out: compile (mix compile --warnings-as-errors) failed with status 1
      Acceptance: Cucumber bridge added in features/steps
      Commit: {sha8} Add Kogen configuration
      """
    And the file ".kogen/project.yaml" contains "    - name: format"
    And the file ".kogen/project.yaml" contains "      run: 'mix format --check-formatted'"
    And the file ".kogen/project.yaml" contains "    - 'mix format'"
    And the file ".kogen/project.yaml" contains "  - '.formatter.exs'"
    And the path "lib/ex_app.ex" has uncommitted changes
    And request 1 contains the text of the file "mix.exs"

  @SET-10 @SET-11 @SET-12
  Scenario: Init configures a Node project with its existing runner and a check the model found
    Given a Git project from fixture "node-app"
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-proposes-docs-check"
    When the caller runs "kogen init"
    Then the exit code is 0
    And stdout is:
      """
      Initialized Kogen in {abs:.}
      Setup: npm ci --no-audit --no-fund
      Checks: test, docs
      Left out: lint (npm run lint) failed with status 2
      Acceptance: existing Cucumber runner, steps in features/step_definitions
      Commit: {sha8} Add Kogen configuration
      """
    And the new commit changes exactly:
      | path                |
      | .gitignore          |
      | .kogen/project.yaml |
    And the file ".kogen/project.yaml" contains "    - name: docs"
    And the file ".kogen/project.yaml" contains "      run: 'node docs-check.js'"
    And request 1 contains the text of the file "README.md"
    Given the fake ChatGPT server plays script "shape-asks-one"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And stdout contains "Questions for is-even"

  @SET-13
  Scenario: An existing runner that does not start is reported and acceptance stays unset
    Given a Git project from fixture "node-app"
    And the committed file "features/step_definitions/app_steps.js" contains "this is not JavaScript"
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-proposes-nothing"
    When the caller runs "kogen init"
    Then the exit code is 0
    And stdout contains "Acceptance: not configured: the runner check failed with status 1"
    And stdout contains "Next: set commands.acceptance in .kogen/project.yaml"

  @SET-11
  Scenario: Two invalid configuration replies end init without writing anything
    Given a Git project from fixture "notes"
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-invalid-twice"
    When the caller runs "kogen init"
    Then the exit code is 4
    And stdout is:
      """
      provider/init_invalid: the model did not return a valid configuration; nothing was written
      """
    And the file ".kogen/project.yaml" does not exist
    And the working tree is unchanged

  @SET-2 @GPT-5
  Scenario: Init without a login writes nothing
    Given a Git project from fixture "notes"
    When the caller runs "kogen init"
    Then the exit code is 4
    And stdout is:
      """
      provider/login: not signed in; run kogen provider login chatgpt
      """
    And the file ".kogen/project.yaml" does not exist

  @SET-2
  Scenario: In a repository without commits, init makes the first commit
    Given a Git project from fixture "empty-repo"
    When the caller runs "kogen init"
    Then the exit code is 0
    And stdout is:
      """
      Initialized Kogen in {abs:.}
      Commit: {sha8} Initial commit (the first commit of this repository)
      Next: set commands.acceptance in .kogen/project.yaml
      Next: add the project's checks to commands.checks in .kogen/project.yaml
      """
    And the new commit's message is:
      """
      Initial commit
      """

  @SET-1
  Scenario: Init outside a Git repository is refused
    Given an empty folder "plain"
    When the caller runs "kogen init" in the folder "plain"
    Then the exit code is 3
    And stdout is:
      """
      environment/not_a_git_repo: {abs:plain}; run git init first
      """

  @SET-2
  Scenario: Init refuses when .gitignore has uncommitted changes
    Given a Git project from fixture "py-calc"
    And the file ".gitignore" is changed outside Kogen
    When the caller runs "kogen init"
    Then the exit code is 5
    And stdout is:
      """
      environment/dirty_tree: .gitignore has uncommitted changes; commit, stash or discard them first
      """

  @SET-3
  Scenario: A second init changes nothing
    Given a Git project from fixture "py-calc"
    And the project is initialized
    When the caller runs "kogen init"
    Then the exit code is 0
    And stdout contains "Kogen is already initialized in {abs:.}"
    And HEAD is unchanged

  @SET-3
  Scenario: Init commits the files that a failed init commit left behind
    Given a Git project from fixture "py-calc"
    And the project has the Kogen configuration and ignore line written but not committed
    When the caller runs "kogen init"
    Then the exit code is 0
    And the new commit changes exactly:
      | path                |
      | .gitignore          |
      | .kogen/project.yaml |

  @SET-4 @SET-8
  Scenario: An invalid config is reported with line numbers
    Given a Git project from fixture "py-calc"
    And the project is initialized
    And the file ".kogen/project.yaml" contains:
      """
      version: 1
      commands:
        checks:
          - name: test
            runn: pytest
      limits:
        build_minutes: 120
      """
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 3
    And stdout contains "environment/project_config_invalid: {abs:.kogen/project.yaml}"
    And stdout contains "  line 5: unknown key runn"
    And stdout contains "  line 6: unknown key limits"

  @SET-5
  Scenario: Init without a Git identity writes nothing
    Given a Git project from fixture "py-calc"
    And git user.name and user.email are not set
    When the caller runs "kogen init"
    Then the exit code is 3
    And stdout is:
      """
      environment/git_identity_missing: configure git user.name and user.email
      """
    And the file ".kogen/project.yaml" does not exist

  @SET-6 @SET-7
  Scenario: Kogen data stays ignored and AGENTS.md never reaches a model
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the committed file "AGENTS.md" contains "SECRET-AGENTS-INSTRUCTION"
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "shape-asks-one"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And the folder ".kogen/local/shaping/is-even" exists
    And the working tree is unchanged
    And request 1 contains the text of the file "README.md"
    And no request contains "SECRET-AGENTS-INSTRUCTION"

  @SET-4
  Scenario: A configuration from the earlier Kogen is named as such and nothing is written
    Given a Git project from fixture "py-calc"
    And the committed file ".kogen/project.yaml" contains "kogen_version: 0.9"
    When the caller runs "kogen init"
    Then the exit code is 3
    And stdout is:
      """
      environment/old_kogen_config: .kogen/ is from an earlier Kogen; move it aside (git mv .kogen .kogen-old), commit, and run kogen init
      """
    And HEAD is unchanged

  @SET-2
  Scenario: Init in a repository whose files are not committed yet asks for the first commit
    Given a Git project from fixture "empty-repo"
    And the file "app.txt" is changed outside Kogen
    When the caller runs "kogen init"
    Then the exit code is 3
    And stdout is:
      """
      environment/no_commits: 1 file(s) are not committed yet; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init
      """

  @SET-10 @SET-13 @SHP-2 @VER-3
  Scenario: The generated bridge shapes and builds in a checkout with spaces
    Given a Git project from fixture "py-calc" in the folder "repo with space"
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-proposes-nothing"
    When the caller runs "kogen init"
    Then the exit code is 0
    Given the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And stdout contains "Scenarios: 3 (3 fail now, 0 pass now)"
    When the caller approves "is-even" with the hash of its acceptance baseline
    Then the exit code is 0
    Given the fake ChatGPT server plays script "build-correct-first-try"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 0
    And stdout contains "checks: acceptance 3/3"
    And stdout contains "landed is-even"

  @SET-12
  Scenario: Init leaves out a setup command that cannot run twice on the same tree
    Given a Git project from fixture "notes"
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "init-proposes-setup"
    When the caller runs "kogen init"
    Then the exit code is 0
    And stdout contains "Setup: true"
    And stdout contains "Left out: setup-1 (mkdir seeded) is not repeatable: its second run failed with status 1; setup-2 (echo run >> runs.txt) is not repeatable: its second run changed runs.txt"
