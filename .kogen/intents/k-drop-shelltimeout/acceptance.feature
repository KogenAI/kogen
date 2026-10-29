Feature: Remove the opt-in shell time limit
  Scenario: Refuse an existing project that names the removed option
    When shelltimeout removal checks a project containing "tool_shell_timeout_seconds" with value "1"
    Then shelltimeout removal diagnostics contain "unknown key tool_shell_timeout_seconds"

  Scenario: Remove active option support
    When shelltimeout removal collects active option references
    Then shelltimeout removal reference paths are "[\"docs/configuration.md\"]"
