Feature: Tested release archives, checksums and a one-line installer
  Release builds run in a disposable clean git copy of the sources, never in the caller's checkout.

  Background:
    Given a clean committed copy of the Kogen sources for release testing

  Scenario: package.sh --target builds every platform from one host
    When I build every release target with package.sh --target
    Then the release archive for each target names that target and holds a binary for it:
      | target        | os     | arch   |
      | darwin-arm64  | darwin | arm64  |
      | darwin-x86_64 | darwin | x86_64 |
      | linux-x86_64  | linux  | x86_64 |
      | linux-arm64   | linux  | arm64  |

  Scenario: release.sh writes the release set with checksums
    When I build the release set with release.sh
    Then the release folder holds exactly the four archives, SHA256SUMS and install-kogen.sh
    And sha256sum accepts SHA256SUMS naming exactly the four archives

  Scenario: release.sh refuses a dirty checkout
    When I run release.sh in a checkout with an uncommitted file
    Then release.sh refuses with a message about a clean checkout and writes no SHA256SUMS

  Scenario: install-kogen.sh installs the host archive from local files
    When I install the host archive with install-kogen.sh from the release folder
    Then the installer succeeds and leaves its temp directory empty
    And kogen --version in the prefix exits 0 and prints exactly what kogen version prints

  Scenario: a tampered archive is refused before extraction
    When I install from a release folder whose host archive was tampered with
    Then the installer refuses with a checksum mismatch message before extracting anything

  Scenario: install.sh refuses an archive for another target
    When I run install.sh from an archive built for another target
    Then install.sh refuses naming both targets and installs nothing

  Scenario: the release workflow has the required jobs
    When I parse the release workflow file
    Then the workflow triggers on pushed v* tags and on pull requests
    And the workflow has the jobs build, install-check, pr-check and draft-release
    And install-check runs the four native runners, installs from local files and checks version and help
    And pr-check builds and installs on ubuntu-24.04 only
    And draft-release creates only a draft with the default token and never publishes
