Feature: The Claude Code token route is not circular and is visible in the provider list
  # A fresh home cannot use Kogen's not-yet-installed runtime to obtain the token
  # required by the role that installs it. An ordinary Claude Code supplies the token.

  Scenario: A fresh home shows claude-code as not signed in with the runtime not installed
    Given claude-code-token-route-not-circular: a compiled CLI and a fresh Kogen home
    When claude-code-token-route-not-circular: I run "kogen provider list"
    Then claude-code-token-route-not-circular: the exit status is 0
    And claude-code-token-route-not-circular: the first four lines are the ChatGPT, SuperGrok, OpenCode Go and Anthropic lines
    And claude-code-token-route-not-circular: the claude-code line is "claude-code: not signed in" and comes right after the Anthropic line
    And claude-code-token-route-not-circular: the runtime line says not installed and comes right after the claude-code line
    And claude-code-token-route-not-circular: the official compatibility text follows the runtime line
    And claude-code-token-route-not-circular: the home has no Claude Code folder

  Scenario: A saved token shows claude-code as token saved with the runtime not installed
    Given claude-code-token-route-not-circular: a compiled CLI and a fresh Kogen home
    And claude-code-token-route-not-circular: a Claude Code token is saved with kogen provider login claude-code from standard input
    When claude-code-token-route-not-circular: I run "kogen provider list"
    Then claude-code-token-route-not-circular: the exit status is 0
    And claude-code-token-route-not-circular: the claude-code line is "claude-code: token saved (not verified)" and comes right after the Anthropic line
    And claude-code-token-route-not-circular: no line is "claude-code: not signed in"
    And claude-code-token-route-not-circular: the runtime line says not installed and comes right after the claude-code line
    And claude-code-token-route-not-circular: the official compatibility text follows the runtime line

  Scenario: An installed runtime without a token shows not signed in and the runtime path while preserving installation
    Given claude-code-token-route-not-circular: a compiled CLI and a fresh Kogen home
    And claude-code-token-route-not-circular: Kogen's Claude Code runtime file is installed in the home
    When claude-code-token-route-not-circular: I run "kogen provider list"
    Then claude-code-token-route-not-circular: the exit status is 0
    And claude-code-token-route-not-circular: the claude-code line is "claude-code: not signed in" and comes right after the Anthropic line
    And claude-code-token-route-not-circular: the runtime line says installed with the home's runtime path and comes right after the claude-code line
    And claude-code-token-route-not-circular: the installed runtime file remains unchanged
    And claude-code-token-route-not-circular: the official compatibility text follows the runtime line

  Scenario: A saved token and an installed runtime show both states
    Given claude-code-token-route-not-circular: a compiled CLI and a fresh Kogen home
    And claude-code-token-route-not-circular: a Claude Code token is saved with kogen provider login claude-code from standard input
    And claude-code-token-route-not-circular: Kogen's Claude Code runtime file is installed in the home
    When claude-code-token-route-not-circular: I run "kogen provider list"
    Then claude-code-token-route-not-circular: the exit status is 0
    And claude-code-token-route-not-circular: the claude-code line is "claude-code: token saved (not verified)" and comes right after the Anthropic line
    And claude-code-token-route-not-circular: no line is "claude-code: not signed in"
    And claude-code-token-route-not-circular: the runtime line says installed with the home's runtime path and comes right after the claude-code line

  Scenario: The JSON form of the provider list is not given claude-code text lines
    Given claude-code-token-route-not-circular: a compiled CLI and a fresh Kogen home
    When claude-code-token-route-not-circular: I run "kogen provider list --json"
    Then claude-code-token-route-not-circular: the exit status is 0
    And claude-code-token-route-not-circular: the output is JSON without any claude-code login or runtime line

  Scenario: The getting-started guide names the working order
    Then claude-code-token-route-not-circular: getting-started gives the working order:
      """
      Run `claude setup-token` with an ordinary Claude Code, then pipe the token to `kogen provider login claude-code`.
      """
    And claude-code-token-route-not-circular: getting-started says the runtime path exists only after a Build or Refine installed it
    And claude-code-token-route-not-circular: getting-started no longer tells a fresh install to run setup-token from the runtime
    And claude-code-token-route-not-circular: the getting-started provider list excerpt has the claude-code lines


  Scenario: The pinned runtime installation lifecycle remains intact offline
    Then claude-code-token-route-not-circular: the existing offline pinned runtime lifecycle tests pass

  Scenario: The rest of the getting-started guide is preserved
    Then claude-code-token-route-not-circular: the unrelated getting-started guide content is preserved
