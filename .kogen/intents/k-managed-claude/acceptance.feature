Feature: Kogen manages its own pinned, isolated Claude Code runtime
  Kogen installs and runs exactly Claude Code 2.1.312 from ~/.kogen/claude-code, never the Claude
  Code on PATH or another version, and leaves the user's own Claude Code setup untouched. The
  download source is the loopback test seam KOGEN_CLAUDE_CODE_URL, which serves the official
  manifest shape and a scripted fake runtime that runs Kogen's hooks like Claude Code does.

  Background:
    Given a managed-runtime user whose PATH has Claude Code "2.1.314" and a customized Claude Code setup

  Scenario: The first Build installs the pinned runtime and every Claude Code role runs on it with Kogen's hooks
    Given an earlier Kogen managed Claude Code runtime "2.1.300" is installed
    And the managed-runtime download server serves a runtime reporting "2.1.312 (Claude Code)"
    And an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build landed "app.txt" with the content "built on the managed Claude Code\n"
    And the managed-runtime output has the line "kogen: installing Claude Code 2.1.312 into <home>/.kogen/claude-code/2.1.312"
    And the managed-runtime output has the line "kogen: installed Claude Code 2.1.312 (sha256 <served-sha256>)"
    And the managed runtime "<home>/.kogen/claude-code/2.1.312/claude" holds exactly the served bytes and is executable
    And the managed-runtime download server served the "2.1.312" runtime 1 time
    And every managed Claude Code child ran "<home>/.kogen/claude-code/2.1.312/claude" with CLAUDE_CONFIG_DIR "<home>/.kogen/claude-code/config" and DISABLE_UPDATES "1"
    And the managed Claude Code runtime served both the build and the review role
    And the Kogen PreToolUse hook allowed the managed Claude Code write of "app.txt"
    And the managed-runtime directory "<home>/.kogen/claude-code/config" exists with mode "700"
    And the managed Claude Code directory holds no partial installation
    And the Claude Code on the PATH of the managed-runtime user was never run
    And the earlier managed Claude Code runtime is unchanged and was never run
    And the own Claude Code setup of the managed-runtime user is byte-for-byte unchanged
    When I list the providers of the managed-runtime user
    Then the managed-runtime provider list has the line "claude-code runtime: Claude Code 2.1.312 installed (<home>/.kogen/claude-code/2.1.312/claude)"

  Scenario: A downloaded runtime that reports an untested version is refused and nothing is installed
    Given the managed-runtime download server serves a runtime reporting "2.1.314 (Claude Code)"
    And an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build was refused with "executor/unavailable" and the message "the downloaded Claude Code reports 2.1.314 (Claude Code), not 2.1.312; nothing was installed"
    And nothing is installed for managed Claude Code "2.1.312"
    And no managed Claude Code round ran
    And the managed-runtime fixture project is unchanged
    And the Claude Code on the PATH of the managed-runtime user was never run
    And the own Claude Code setup of the managed-runtime user is byte-for-byte unchanged

  Scenario: A downloaded runtime whose bytes do not match the pinned checksum is never started
    Given the managed-runtime download server serves a runtime whose bytes do not match its manifest checksum
    And an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build was refused with "executor/unavailable" and the message "the downloaded Claude Code 2.1.312 does not match its pinned SHA-256; nothing was installed"
    And nothing is installed for managed Claude Code "2.1.312"
    And no downloaded or installed managed Claude Code runtime was started
    And the managed-runtime fixture project is unchanged
    And the Claude Code on the PATH of the managed-runtime user was never run

  Scenario: An installed runtime that reports another version is refused, never replaced or bypassed
    Given the managed Claude Code runtime "2.1.312" is already installed reporting "2.1.314 (Claude Code)"
    And the managed-runtime download server serves a runtime reporting "2.1.312 (Claude Code)"
    And an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build was refused with "executor/unavailable" and the message "Kogen's Claude Code at <home>/.kogen/claude-code/2.1.312/claude reports 2.1.314 (Claude Code), not the pinned 2.1.312; remove <home>/.kogen/claude-code/2.1.312 to reinstall it"
    And the managed-runtime download server received no request
    And no managed Claude Code round ran
    And the managed-runtime fixture project is unchanged
    And the Claude Code on the PATH of the managed-runtime user was never run

  Scenario: An interrupted installation leaves nothing installed and the next Build recovers
    Given a leftover ".partial-killed" directory from an interrupted managed Claude Code installation
    And the managed-runtime download server drops the connection halfway through the runtime
    And an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build was refused with "executor/unavailable" and the message "cannot download Claude Code 2.1.312 from <server>/2.1.312/<platform>/claude"
    And nothing is installed for managed Claude Code "2.1.312"
    And no managed Claude Code round ran
    And the managed-runtime fixture project is unchanged
    Given the managed-runtime download server serves a runtime reporting "2.1.312 (Claude Code)"
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build landed "app.txt" with the content "built on the managed Claude Code\n"
    And the managed runtime "<home>/.kogen/claude-code/2.1.312/claude" holds exactly the served bytes and is executable
    And the managed-runtime download server served the "2.1.312" runtime 2 times
    And the managed Claude Code directory holds no partial installation
    And the Claude Code on the PATH of the managed-runtime user was never run

  Scenario: Kogen's runtime that is not signed in is refused with Kogen's login route
    Given the managed Claude Code runtime "2.1.312" is already installed and reports that it is not signed in
    And an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor
    When I build the managed-runtime fixture Intent
    Then the managed-runtime Build was refused with "executor/auth_refused" and the message "Kogen's Claude Code is not signed in; make a token with `claude setup-token` and save it with `kogen provider login claude-code`"
    And every managed Claude Code child ran "<home>/.kogen/claude-code/2.1.312/claude" with CLAUDE_CONFIG_DIR "<home>/.kogen/claude-code/config" and DISABLE_UPDATES "1"
    And no managed Claude Code round ran
    And the managed-runtime fixture project is unchanged
    And the Claude Code on the PATH of the managed-runtime user was never run

  Scenario: The provider list reports a pinned runtime that is not installed yet
    Given the managed-runtime user saved the Claude Code token "sk-ant-oat01-SYNTHETIC-MANAGED-0001"
    When I list the providers of the managed-runtime user
    Then the managed-runtime provider list has the line "claude-code runtime: Claude Code 2.1.312 not installed" right after the line "claude-code: token saved (not verified)"

  Scenario: Uninstall removes what Kogen owns and keeps the user's credentials and own setup
    Given the managed Claude Code runtime "2.1.312" is already installed reporting "2.1.312 (Claude Code)"
    And an earlier Kogen managed Claude Code runtime "2.1.300" is installed
    And the managed Claude Code configuration directory holds session data
    And the managed-runtime user saved the Claude Code token "sk-ant-oat01-SYNTHETIC-MANAGED-0002"
    When I uninstall the managed-runtime Kogen
    Then the managed-runtime uninstall succeeded with the line "Removed Kogen's Claude Code runtime from <home>/.kogen/claude-code"
    And the managed-runtime path "<home>/.kogen/claude-code" does not exist
    And the saved Claude Code token of the managed-runtime user is unchanged
    And the own Claude Code setup of the managed-runtime user is byte-for-byte unchanged
    And the Claude Code on the PATH of the managed-runtime user was never run
