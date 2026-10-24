@live
Feature: Release acceptance on real projects
  Run by the real-use script (REL-1) from a fresh login shell on each
  platform with the real ChatGPT route; not part of the deterministic suite.

  @REL-1 @REL-2
  Scenario Outline: Install, shape, approve, build, interrupt, rebuild, verify, review, commit, uninstall
    Given a fresh user home on "<platform>"
    And the release archive downloaded with curl and installed with install.sh
    And a fresh clone of "<project>"
    When the caller signs in with the real ChatGPT browser flow and kogen provider list shows the login
    And the caller runs kogen init and configures the project's commands
    And the caller shapes the project's request and answers any question it asks
    And the caller reviews the Intent and step files and approves them
    And the caller starts the Build and sends SIGINT during it
    Then the Build stops within 15 seconds with exit code 130 and no commit
    When the caller discards the listed edits and builds again
    Then the Build runs at least one tool call, lands with review approved and the transcript records whether a repair happened
    And the project's own acceptance command and tests pass on the new commit without Kogen
    And the new commit has the Intent title, the Kogen-Intent trailer, no AI attribution and a signature exactly as the host's Git configuration says
    And no Kogen process is alive and no credential token appears in any project or log file
    When the caller runs kogen uninstall
    Then kogen is gone and the project and ~/.kogen are intact

    Examples:
      | platform     | project      |
      | darwin-arm64 | example      |
      | darwin-arm64 | kogen        |
      | linux-x86_64 | example      |
      | linux-x86_64 | kogen        |

    @external
    Examples:
      | platform     | project      |
      | darwin-arm64 | external     |
      | linux-x86_64 | external     |

  @REL-3
  Scenario: The self-built Kogen works after it is packaged and installed
    Given a disposable repository with the candidate Kogen source and an ordinary Git baseline
    When the installed Kogen shapes and builds one small Kogen change there
    Then the candidate's deterministic suite passes with an isolated HOME and no real credentials
    And the candidate is packaged, installed into a separate prefix and the change is observed outside its checkout

  @REL-4 @REL-5 @REL-6 @REL-7
  Scenario: The release boundary
    Given a clean checkout of the release commit
    When the full deterministic suite and the packaging run from that checkout
    Then no required scenario is pending, skipped, undefined or excluded and spec/check.sh passes
    And go test ./... passes on both platforms
    And the release built from that checkout reports the commit's short hash
