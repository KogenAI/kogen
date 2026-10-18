Feature: CLI and process
  The command tree and grammar, errors and exit codes, interruption that
  stops a Build without a commit, and the Go/Elixir bridge.

  Background:
    Given a clean Kogen home
    And the installed kogen command

  @CLI-1 @CLI-3
  Scenario: The top help page lists the commands
    When the caller runs "kogen"
    Then the exit code is 0
    And stdout is:
      """
      Commands:
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to ChatGPT and show the login
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """

    When the caller runs "kogen --help"
    Then the exit code is 0
    And stdout is:
      """
      Commands:
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to ChatGPT and show the login
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """
    When the caller runs "kogen -h"
    Then the exit code is 0
    And stdout is:
      """
      Commands:
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to ChatGPT and show the login
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """
    When the caller runs "kogen init --help"
    Then the exit code is 0
    And stdout is:
      """
      Commands:
        init       Prepare this Git repository for Kogen
        intent     Shape, approve and build an Intent
        provider   Sign in to ChatGPT and show the login
        uninstall  Remove the installed kogen
        version    Show the Kogen version
        help       List commands

      Run kogen <command> to see its subcommands and options.
      """

  @CLI-2 @CLI-3
  Scenario Outline: Command help flags print the existing command page
    When the caller runs "<command>"
    Then the exit code is 0
    And stdout matches "<first_line>"

    Examples:
      | command                      | first_line                          |
      | kogen help --help            | ^Commands:                          |
      | kogen intent --help          | ^Usage: kogen intent                |
      | kogen intent shape --help    | ^Usage: kogen intent                |
      | kogen intent approve -h      | ^Usage: kogen intent                |
      | kogen intent build --help    | ^Usage: kogen intent                |
      | kogen provider --help        | ^Usage: kogen provider              |
      | kogen provider list --help   | ^Usage: kogen provider              |
      | kogen provider login -h      | ^Usage: kogen provider              |
      | kogen uninstall --help       | ^Commands:                          |
      | kogen version --help         | ^Commands:                          |

  @CLI-2 @CLI-3
  Scenario Outline: Usage errors print the message, a blank line and the page meant
    When the caller runs "<command>"
    Then the exit code is 2
    And the first line of stdout is "<message>"
    And the rest of stdout after a blank line is the help page "<page>" from chapter 09

    Examples:
      | command                         | message                                                            | page     |
      | kogen frobnicate                | kogen: unknown command 'frobnicate'                                | top      |
      | kogen queue start               | kogen: unknown command 'queue'                                     | top      |
      | kogen intent frob               | kogen intent: unknown command 'frob'                               | intent   |
      | kogen intent build              | kogen intent build: missing <slug>                                 | intent   |
      | kogen intent build a --detach   | kogen intent build: unknown option '--detach'                      | intent   |
      | kogen intent shape a b c        | kogen intent shape: unexpected argument 'c'                        | intent   |
      | kogen provider login grok       | kogen provider login: unknown provider 'grok' (supported: chatgpt) | provider |

  @CLI-2
  Scenario: The last repeated option wins and a missing project folder is an environment error
    Given a Git project from fixture "py-calc" in the folder "a"
    And a Git project from fixture "py-calc" in the folder "b"
    And the project is initialized and configured
    And the Intent "is-even" from fixture "is-even" is shaped
    When the caller runs "kogen intent approve is-even --project a --project=b"
    Then the exit code is 5
    When the caller runs "kogen intent build is-even --project nowhere"
    Then the exit code is 3
    And stdout is:
      """
      environment/project_unavailable: {abs:nowhere}
      """

  @CLI-4 @CLI-9
  Scenario: Core logging never reaches stdout
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the Intent "is-even" from fixture "is-even" is shaped
    And the Kogen core logs at debug level
    When the caller runs "kogen intent approve is-even"
    Then the first line of stdout is "Intent: is-even — Add an is-even helper"
    And stderr contains core log lines
    And stdout does not contain "[debug]"

  @CLI-5 @CLI-6
  Scenario: A Build that does not commit has its own reason, never an internal error
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-review-invalid-twice"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 1
    And stdout contains "failed is-even: review_invalid (Build "
    And stdout does not contain "controller/internal_error"

  @CLI-7 @model:run_control
  Scenario Outline: An interrupt stops the Build without a commit
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And a pre-commit hook that sleeps for 600 seconds
    And the fake ChatGPT server plays script "build-correct-first-try" pausing at "<point>"
    And the caller runs "kogen intent build is-even" in the background
    And the fake ChatGPT server reaches "<point>"
    When the caller sends <signal> to the kogen command
    Then within 15 seconds the kogen command has exited
    And the exit code is <exit>
    And stdout contains "stopped is-even: interrupted (Build "
    And stdout contains "stopped by <signal>; edits are left in place"
    And HEAD is unchanged
    And no process of the Build command's process group is running
    And the file ".kogen/local/build.lock" does not exist

    Examples:
      | point                  | signal  | exit |
      | builder request in flight | SIGINT  | 130  |
      | tool command running   | SIGTERM | 143  |
      | review approved        | SIGINT  | 130  |
      | tool command running   | SIGHUP  | 129  |
      | git commit running     | SIGINT  | 130  |

  @CLI-7 @model:run_control
  Scenario: When the kogen command dies, the core cancels the Build by itself
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "sleep 600"
    And the caller runs "kogen intent build is-even" in the background
    And the fake ChatGPT server reaches "tool command running"
    When the caller sends SIGKILL to the kogen command
    Then within 15 seconds no process of the Build command's process group is running
    And HEAD is unchanged
    And the file ".kogen/local/build.lock" does not exist

  @CLI-7
  Scenario: An interrupt during a readiness dry run stops its commands
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the Intent "is-even" from fixture "is-even" is shaped
    And the acceptance command is replaced by fixture runner "hangs"
    And the caller runs "kogen intent approve is-even" in the background
    And the readiness command is running
    When the caller sends SIGINT to the kogen command
    Then within 15 seconds the kogen command has exited
    And the exit code is 130
    And no process of the Build command's process group is running

  @CLI-7
  Scenario: A command that ignores SIGTERM is killed after the grace period
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "trap '' TERM; sleep 600"
    And the caller runs "kogen intent build is-even" in the background
    And the fake ChatGPT server reaches "tool command running"
    When the caller sends SIGINT to the kogen command
    Then within 15 seconds the kogen command has exited
    And no process of the Build command's process group is running

  @CLI-8 @model:run_control
  Scenario: A core crash is reported and nothing is committed
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "sleep 600"
    And the caller runs "kogen intent build is-even" in the background
    And the fake ChatGPT server reaches "tool command running"
    When the caller sends SIGKILL to the Kogen core
    Then within 15 seconds the kogen command has exited
    And the exit code is 70
    And stdout contains "controller/internal_error: the Kogen core stopped unexpectedly (status "
    And stdout contains "nothing was committed"
    And no process of the Build command's process group is running
    And HEAD is unchanged

  @CLI-8
  Scenario: A core crash right after the commit reports the commit honestly
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-correct-first-try"
    And the test build of the core pauses right after creating the commit
    And the caller runs "kogen intent build is-even" in the background
    When the core reaches the pause after the commit
    And the caller sends SIGKILL to the Kogen core
    Then within 15 seconds the kogen command has exited
    And the exit code is 70
    And stdout contains "after creating commit "
    And stdout contains "before checking it; inspect it with git show "
    And HEAD has 1 new commit

  @CLI-9
  Scenario: A missing core is an environment error
    Given the installed core release is missing
    When the caller runs "kogen version"
    Then the exit code is 3
    And stdout contains "environment/core_unavailable: "

  @CLI-9
  Scenario: SIGINT sent straight to the core changes nothing; cancellation comes only from kogen
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-runs-command" with command "sleep 600"
    And the caller runs "kogen intent build is-even" in the background
    And the fake ChatGPT server reaches "tool command running"
    When the caller sends SIGINT to the Kogen core
    Then the kogen command is still running
    And every stdout line so far is protocol output of kogen
    When the caller sends SIGINT to the kogen command
    Then within 15 seconds the kogen command has exited
    And the exit code is 130
    And HEAD is unchanged

  @CLI-10
  Scenario Outline: Version works anywhere without a login
    When the caller runs "<command>" in the folder "/"
    Then the exit code is 0
    And stdout matches "^kogen ([0-9a-f]{8} [(][0-9]{4}-[0-9]{2}-[0-9]{2}[)]|dev[+][0-9a-f]{8} [(][0-9]{4}-[0-9]{2}-[0-9]{2}, uncommitted source[)])$"

    Examples:
      | command         |
      | kogen version   |
      | kogen --version |
