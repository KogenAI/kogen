Feature: Distinguish Claude auth probe failures from logout
  This feature reproduces ev-d5397b30 through readiness.Run and readiness.Text,
  the report entry points used by init. All fixtures use Kogen's managed runtime,
  the existing pinned version, supported platform, and no stored token.

  Scenario: Confirmed logged out keeps its existing diagnosis and fix
    Given readiness-claude-auth-probe-errors: a managed Claude Code without a stored token returns exit 0 and auth status:
      """
      {"loggedIn":false}
      """
    When readiness-claude-auth-probe-errors: the public readiness report is produced
    Then readiness-claude-auth-probe-errors: the models report satisfies:
      """
      {"status":"fail","message":"claude-code: no stored token and no claude.ai subscription sign-in","fix":"kogen provider login claude-code"}
      """

  Scenario: Nonzero auth probe is unavailable even with signed-in JSON
    Given readiness-claude-auth-probe-errors: a managed Claude Code without a stored token returns exit 7 and auth status:
      """
      {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}
      """
    When readiness-claude-auth-probe-errors: the public readiness report is produced
    Then readiness-claude-auth-probe-errors: the models report satisfies:
      """
      {"status":"fail","diagnosis":"unavailable"}
      """

  Scenario: Malformed auth JSON is not confirmed logout
    Given readiness-claude-auth-probe-errors: a managed Claude Code without a stored token returns exit 0 and auth status:
      """
      {not-json
      """
    When readiness-claude-auth-probe-errors: the public readiness report is produced
    Then readiness-claude-auth-probe-errors: the models report satisfies:
      """
      {"status":"fail","diagnosis":"invalid or unavailable"}
      """

  Scenario: Valid subscription sign-in stays ready
    Given readiness-claude-auth-probe-errors: a managed Claude Code without a stored token returns exit 0 and auth status:
      """
      {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}
      """
    When readiness-claude-auth-probe-errors: the public readiness report is produced
    Then readiness-claude-auth-probe-errors: the models report satisfies:
      """
      {"status":"ok","message":"shape, build, review ready","fix":""}
      """
