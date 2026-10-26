Feature: Install and uninstall
  One kogen command per user from a per-platform archive; kogen uninstall
  removes what the installer placed.

  Background:
    Given a clean Kogen home
    And the release archive for this platform, extracted with tar

  @INS-2 @INS-3 @INS-4
  Scenario: Install into the default prefix and run from anywhere without Erlang, Elixir or Go
    Given no erl, elixir, mix or go program is on PATH
    When the caller runs "sh install.sh"
    Then the exit code is 0
    And the last line of stdout matches "^Installed kogen (dev[+])?[0-9a-f]{8} in .+/[.]local$"
    And the file "{home}/.local/bin/kogen" is a symlink into "{home}/.local/lib/kogen/"
    And the file "{home}/.local/lib/kogen/docs/testing-rules.md" exists
    And the file "{home}/.local/lib/kogen/docs/configuration.md" exists
    And the file "{home}/.local/lib/kogen/LICENSE" exists
    And the file "{home}/.local/lib/kogen/NOTICE" exists
    And the file "{home}/.local/lib/kogen/lib/VERSION" exists
    And the file "{home}/.local/lib/kogen/lib/VERSION.json" exists
    And the folder "{home}/.local/lib/kogen/lib/release" does not exist
    And the file "{home}/.local/lib/kogen/licenses/npm-packages.md" contains "@cucumber/cucumber"
    And the file "{home}/.local/lib/kogen/lib/cucumber/node_modules/@cucumber/cucumber/bin/cucumber.js" exists
    When the caller runs "{home}/.local/bin/kogen version" in the folder "/"
    Then the exit code is 0

  @INS-4
  Scenario: The installer installs Node when it is missing
    Given a local Node distribution serves the real pinned Node and a newer non-LTS catalog entry
    And the program "node" is not on PATH
    When the caller runs "sh install.sh"
    Then the exit code is 0
    And the file "{home}/.local/lib/kogen/node/bin/node" exists
    And the file "{home}/.local/lib/kogen/node-path" contains "{home}/.local/lib/kogen/node/bin/node"
    And the installer downloaded the catalog and selected LTS archive from the local Node distribution
    And the installed Node reports the real fixture version

  @INS-4
  Scenario: Node 22 or newer on PATH is recorded and nothing is downloaded
    Given node 22 or newer is on PATH
    When the caller runs "sh install.sh"
    Then the exit code is 0
    And the file "{home}/.local/lib/kogen/node-path" contains "{path_node}"
    And the folder "{home}/.local/lib/kogen/node" does not exist

  @INS-4
  Scenario: A prefix outside PATH gets a hint and no shell file is edited
    When the caller runs "sh install.sh --prefix {home}/opt"
    Then the exit code is 0
    And stdout contains "Add to PATH: export PATH="
    And no file in "{home}" outside "{home}/opt" changed

  @INS-4
  Scenario: A failing self-check fails the install with its output
    Given the extracted archive has no lib/VERSION
    When the caller runs "sh install.sh"
    Then the exit code is 1
    And stdout matches "^environment/[a-z_]+: "
    And stdout contains "reinstall Kogen"

  @INS-1
  Scenario: An unsupported platform is refused
    Given uname reports "Linux" and "aarch64"
    When the caller runs "sh install.sh"
    Then the exit code is 1
    And stdout contains "install: unsupported platform linux-aarch64"

  @INS-5
  Scenario: kogen uninstall removes the program and keeps projects and the login
    Given the caller ran "sh install.sh"
    And the caller is signed in to ChatGPT
    And a Git project from fixture "py-calc"
    And the project is initialized
    And the file "{home}/.kogen/credentials/anthropic.json" contains:
      """
      {"provider":"anthropic","api_key":"SYNTHETIC_UNINSTALL_KEY"}
      """
    And the file "{home}/.kogen/credentials/anthropic.lock" contains:
      """
      SYNTHETIC_PRESERVED_LOCK
      """
    When the caller runs "{home}/.local/bin/kogen uninstall"
    Then the exit code is 0
    And stdout is:
      """
      Uninstalled kogen from {home}/.local
      Kept your ChatGPT, SuperGrok, OpenCode Go, Anthropic and OpenAI-compatible logins; remove it with: rm -f ~/.kogen/credentials/chatgpt.json ~/.kogen/credentials/chatgpt.lock ~/.kogen/host-id ~/.kogen/credentials/supergrok.json ~/.kogen/credentials/supergrok.lock ~/.kogen/credentials/opencode-go.json ~/.kogen/credentials/opencode-go.lock ~/.kogen/credentials/anthropic.json ~/.kogen/credentials/anthropic.lock ~/.kogen/credentials/openai-compatible.json ~/.kogen/credentials/openai-compatible.lock
      """
    And the file "{home}/.local/bin/kogen" does not exist
    And the folder "{home}/.local/lib/kogen" does not exist
    And the file "{home}/.kogen/credentials/chatgpt.json" exists
    And the file "{home}/.kogen/credentials/anthropic.json" exists
    And the file "{home}/.kogen/credentials/anthropic.lock" exists
    And the file ".kogen/project.yaml" exists

  @INS-2
  Scenario: Release archives own their public modes independently of copied inputs and caller umask
    When I package public payloads with all executable bit classes under both caller umasks
    Then the public payloads preserve their contents and inputs with explicit public modes
