Feature: Drop the duplicate Homebrew workflow
  This feature removes the redundant tap-update workflow while keeping the README install docs for brew install KogenAI/tap/kogen.

  Scenario: The duplicate workflow, script and their tests are removed
    Given release-drop-duplicate-homebrew-workflow: the repository checkout
    Then release-drop-duplicate-homebrew-workflow: these paths do not exist
      | .github/workflows/homebrew.yml |
      | packaging/update-homebrew.sh |
      | .kogen/intents/release-updates-brew-formula-and-docs |
      | features/steps/release-updates-brew-formula-and-docs__steps.js |
      | features/steps/release-updates-brew-formula-and-docs__driver |

  Scenario: No workflow updates the Homebrew tap on release publication
    Given release-drop-duplicate-homebrew-workflow: the repository checkout
    Then release-drop-duplicate-homebrew-workflow: no workflow mentions homebrew-tap or HOMEBREW_TAP_TOKEN

  Scenario: README still documents Homebrew install
    Given release-drop-duplicate-homebrew-workflow: the repository checkout
    Then release-drop-duplicate-homebrew-workflow: README.md contains "brew install KogenAI/tap/kogen" ignoring case
    And release-drop-duplicate-homebrew-workflow: README.md contains "Platforms: macOS arm64, macOS x86-64, Linux x86-64 and Linux arm64." ignoring case
