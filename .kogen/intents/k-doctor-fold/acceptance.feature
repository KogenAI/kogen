Feature: kogen doctor is folded into init and the existing commands' errors

  Scenario: kogen doctor is an unknown command with the CLI's usual usage error
    Given a fold folder outside any Git repository
    When the fold caller runs kogen "doctor"
    Then the fold exit status is 2
    And the fold stdout is:
      """
      kogen: unknown command 'doctor'

      Commands:
        context    Read checkout-local facts (JSON)
        completion zsh  Print standalone Zsh completion
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to a provider and show logins
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """
    When the fold caller runs kogen "doctor --quick --json --project ."
    Then the fold exit status is 2
    And the fold stdout is:
      """
      kogen: unknown command 'doctor'

      Commands:
        context    Read checkout-local facts (JSON)
        completion zsh  Print standalone Zsh completion
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to a provider and show logins
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """

  Scenario: The help pages do not list doctor
    Given a fold folder outside any Git repository
    When the fold caller runs kogen "help"
    Then the fold exit status is 0
    And the fold stdout is:
      """
      Commands:
        context    Read checkout-local facts (JSON)
        completion zsh  Print standalone Zsh completion
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to a provider and show logins
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """
    When the fold caller runs kogen ""
    Then the fold exit status is 0
    And the fold stdout is:
      """
      Commands:
        context    Read checkout-local facts (JSON)
        completion zsh  Print standalone Zsh completion
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to a provider and show logins
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """
    When the fold caller runs kogen "init --help"
    Then the fold exit status is 0
    And the fold stdout is:
      """
      Commands:
        context    Read checkout-local facts (JSON)
        completion zsh  Print standalone Zsh completion
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to a provider and show logins
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """

  Scenario: kogen init on a fresh project reports readiness in its own output
    Given a fold repository with one commit, a Git identity and a ChatGPT login
    When the fold caller runs kogen init with a scripted provider that proposes no commands
    Then the fold exit status is 0
    And the fold commit at HEAD has the subject "Add Kogen configuration"
    And the fold stdout is:
      """
      Initialized Kogen in {repo}
      Setup: none
      Checks: none found
      Acceptance: Cucumber bridge added in features/steps
      Commit: {sha8} Add Kogen configuration
      Next: add the project's checks to commands.checks in .kogen/project.yaml
      ok install - {version}; node, cucumber and quint run
      ok git - repository {repo}
      ok config - .kogen/project.yaml is valid
      ok models - shape, build, review ready
      """

  Scenario: kogen init in an empty repository without a login reports the missing login and its fix and still succeeds
    Given a fold empty Git repository with a Git identity and no provider login
    When the fold caller runs kogen "init"
    Then the fold exit status is 0
    And the fold commit at HEAD has the subject "Initial commit"
    And the fold stdout is:
      """
      Initialized Kogen in {repo}
      Commit: {sha8} Initial commit (the first commit of this repository)
      Next: set commands.acceptance in .kogen/project.yaml
      Next: add the project's checks to commands.checks in .kogen/project.yaml
      ok install - {version}; node, cucumber and quint run
      ok git - repository {repo}
      ok config - .kogen/project.yaml is valid
      fail models - shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login
        fix: kogen provider login chatgpt
      """

  Scenario: A command run without a model login fails with a message naming the fix
    Given a fold repository with a committed Kogen configuration, a Git identity and no provider login
    When the fold caller runs kogen "intent shape greeting -" with stdin "Add a greeting."
    Then the fold exit status is 4
    And the fold stdout is:
      """
      provider/login: not signed in; run kogen provider login chatgpt
      """

  Scenario: A command run without configuration fails with a message naming the fix
    Given a fold repository with one commit, a Git identity and a ChatGPT login
    When the fold caller runs kogen "intent shape greeting -" with stdin "Add a greeting."
    Then the fold exit status is 3
    And the fold stdout is:
      """
      environment/not_initialized: {repo} has no .kogen/project.yaml; run kogen init
      """

  Scenario: kogen init without a Git identity names the exact commands that fix it
    Given a fold repository with one commit and no Git identity
    When the fold caller runs kogen "init"
    Then the fold exit status is 3
    And the fold stdout is:
      """
      environment/git_identity_missing: no Git user.name and user.email; run git config user.name "<name>" and git config user.email "<email>" (global or repository)
      """
    And the fold repository has no file ".kogen/project.yaml"

  Scenario: The README, guides and specification no longer describe a doctor command
    Then none of these maintained files contains "doctor", ignoring case:
      | README.md                                |
      | docs/getting-started.md                  |
      | docs/configuration.md                    |
      | spec/prose/01-project-setup.md           |
      | spec/prose/09-cli-and-process.md         |
      | spec/features/01-project-setup.feature   |
      | spec/features/09-cli-and-process.feature |
      | test/acceptance/support/handlers.js      |
    And none of these maintained files contains "skipped with --quick", ignoring case:
      | spec/features/01-project-setup.feature |
      | docs/getting-started.md                |
