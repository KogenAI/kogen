Feature: Bind compatible login keys to user supplied origins
  Only the existing compatible login changes. All tests use temporary fixture homes,
  never real credentials or external inference services. Never kill by name or pattern.

  Scenario: Read two piped lines without consulting repository configuration
    # Test input is exactly https://a.example/v1\nKEY\n.
    # Assert prompts Base URL: then API key:, credential origin https://a.example,
    # api_key KEY, and repository base_url https://b.example/v1 has no influence.
    Then the namedfeedback regression "TestCompatibleLoginUserOrigin" runs exactly once and passes in "."

  Scenario: Use the saved key only for its matching role origin
    # Save via the actual login with https://a.example/v1 then KEY.
    # The real role/request path at https://a.example/v1 works with Bearer KEY.
    # https://b.example/v1 fails before any transport call with the origin error
    # and a hint to run kogen provider login openai-compatible again.
    Then the namedfeedback regression "TestCompatibleLoginRoleOrigins" runs exactly once and passes in "."

  Scenario: Reject a saved key predating origin binding
    # Fixture JSON has provider openai-compatible and api_key KEY, without origin.
    # The error reaches the user with the re-login command and no request is sent.
    Then the namedfeedback regression "TestCompatibleLoginLegacyOriginHint" runs exactly once and passes in "."

  Scenario: Restore installed compatible pipe and private terminal coverage
    # Compatible cases supply https://a.example/v1 before each key.
    # Retain other providers and assert compatible subtests actually ran, not skipped.
    Then the namedfeedback regression "TestInstalledKeyLoginUnderPipesAndATerminal" runs exactly once and passes in "."

  Scenario: Publish the changed login contract in help docs and spec
    # Help and configuration/spec describe URL then private key, origin binding,
    # repository independence and re-login; no new command/subcommand/flag.
    Then the namedfeedback regression "TestCompatibleLoginContractText" runs exactly once and passes in "."
