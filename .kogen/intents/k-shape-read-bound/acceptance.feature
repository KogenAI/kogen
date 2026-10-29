Feature: Shape probes run without the caller's secrets
  Shape's Kogen-owned probe boundary strips inherited credentials without changing the CLI.
  Tests use temporary fixture homes only, never real credentials or unrelated processes.

  Scenario: Caller credentials and saved logins are absent from probes
    Then the namedfeedback regression "TestShapeProbeMinimalEnvironment" runs exactly once and passes in "./verify"

  Scenario: Native Shape keeps ordinary probes working through the boundary
    Then the namedfeedback regression "TestShapeProbeMinimalEnvironmentWiring" runs exactly once and passes in "./shape"
