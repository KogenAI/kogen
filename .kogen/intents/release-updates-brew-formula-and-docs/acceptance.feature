Feature: Synchronize Homebrew with published releases
  This feature reproduces the tap lagging the installer by seven minutes and checks release failure visibility without external writes.

  Scenario: Update the previous tap release
    Given release-updates-brew-formula-and-docs: a release from "v0.1.0-dev.47236bbb" to "v0.1.0-dev.40efd025"
    When release-updates-brew-formula-and-docs: the release tap procedure runs with "success"
    Then release-updates-brew-formula-and-docs: the remote formula matches SHA256SUMS

  Scenario: Report a failed tap update
    Given release-updates-brew-formula-and-docs: a release from "v0.1.0-dev.47236bbb" to "v0.1.0-dev.40efd025"
    When release-updates-brew-formula-and-docs: the release tap procedure runs with "updater failure"
    Then release-updates-brew-formula-and-docs: the update fails visibly

  Scenario: Reject an archive inconsistent with SHA256SUMS
    Given release-updates-brew-formula-and-docs: a release from "v0.1.0-dev.47236bbb" to "v0.1.0-dev.40efd025"
    When release-updates-brew-formula-and-docs: the release tap procedure runs with "checksum mismatch"
    Then release-updates-brew-formula-and-docs: the update fails visibly

  Scenario: Wire published releases
    Then release-updates-brew-formula-and-docs: publication is wired to the tap procedure

  Scenario: Document both install methods
    Then release-updates-brew-formula-and-docs: Install documents these methods
      | curl -fsSL https://get.kogen.dev \| sh | darwin-arm64, darwin-x86_64, linux-x86_64, linux-arm64 |
      | brew install KogenAI/tap/kogen         | macOS Apple Silicon, Linux x86-64 with glibc         |
