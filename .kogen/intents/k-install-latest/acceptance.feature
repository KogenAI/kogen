Feature: The installer finds the Latest release without the rate-limited GitHub API
  Without --version, install-kogen.sh resolves the Latest tag once from the
  https://github.com/KogenAI/kogen/releases/latest redirect, falls back to the GitHub API,
  and downloads that one version's archive and SHA256SUMS. Local fakes of github.com and
  api.github.com, reached through a curl wrapper on PATH, stand in for the network.

  Scenario: the releases/latest redirect finds Latest while the API answers 403
    Given a fake github.com whose releases/latest redirects to the tag "v9.9.9-test"
    And a fake GitHub API that answers HTTP 403 rate limit exceeded
    When I pipe install-kogen.sh to sh with no options through the fakes
    Then the installer exits 0 and the installed kogen reports "v9.9.9-test"
    And the fake github.com was asked for releases/latest exactly once
    And the fake GitHub API was asked 0 times
    And the only downloads were the "v9.9.9-test" archive for this platform and its SHA256SUMS, once each

  Scenario: the GitHub API still finds Latest when the redirect fails
    Given a fake github.com whose releases/latest answers HTTP 503
    And a fake GitHub API whose Latest release is "v9.9.9-test"
    When I pipe install-kogen.sh to sh with no options through the fakes
    Then the installer exits 0 and the installed kogen reports "v9.9.9-test"
    And the fake github.com was asked for releases/latest exactly once
    And the fake GitHub API was asked 1 time
    And the only downloads were the "v9.9.9-test" archive for this platform and its SHA256SUMS, once each

  Scenario: when both ways fail the message names each cause and the --version workaround
    Given a fake github.com whose releases/latest answers HTTP 503
    And a fake GitHub API that answers HTTP 403 rate limit exceeded
    When I pipe install-kogen.sh to sh with no options through the fakes
    Then the installer exits 1 and installs nothing
    And nothing was downloaded
    And the installer output has these lines in this order:
      """
      install-kogen: could not find the latest release
      install-kogen: https://github.com/KogenAI/kogen/releases/latest answered HTTP 503
      install-kogen: https://api.github.com/repos/KogenAI/kogen/releases/latest answered HTTP 403
      install-kogen: to install a chosen release instead, pass its tag from https://github.com/KogenAI/kogen/releases with --version, for example: curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh -s -- --version <tag>
      """
    And the fake github.com was asked for releases/latest exactly once
    And the fake GitHub API was asked 1 time
