Feature: Caller-opted native shell duration
  Scenario Outline: Validate the optional scalar when loading configuration
    When shellbound loads the setting <value>
    Then shellbound configuration is <outcome> naming "tool_shell_timeout_seconds"
    Examples:
      | value            | outcome  |
      | absent           | accepted |
      | 1                | accepted |
      | 2                | accepted |
      | 0                | refused  |
      | -1               | refused  |
      | 1.5              | refused  |
      | 'one'            | refused  |
      | {unknown: 1}     | refused  |
      | {seconds: 1}     | refused  |

  Scenario: Omission leaves a three-second shell unbounded
    When shellbound runs native "build" with setting "absent" and command "sleep 3"
    Then shellbound lands with ordinary result "exit status: 0\n"
    And shellbound advertises "Commands have no time limit."

  Scenario: Opt-in produces ordinary timeout feedback and continues
    When shellbound runs native "build" with setting "1" and command "sleep 3"
    Then shellbound lands with result starting "timed out after 1s\n"
    And shellbound advertises "Each shell call has a caller-configured time limit of 1s."

  Scenario: A timeout removes the group before returning feedback
    When shellbound runs native "group" with setting "1" and command "sleep 3"
    Then shellbound lands with result starting "timed out after 1s\n"
    And shellbound observed the owned group absent at the next model request

  Scenario: Finishing before the bound keeps ordinary combined output
    When shellbound runs native "build" with setting "1" and command "printf 'out\n'; printf 'err\n' >&2; exit 7"
    Then shellbound lands with ordinary result "exit status: 7\nout\nerr\n"

  Scenario: Independent Review uses the bound too
    When shellbound runs native "review" with setting "1" and command "sleep 3"
    Then shellbound lands with result starting "timed out after 1s\n"
    And shellbound advertises "Each shell call has a caller-configured time limit of 1s."

  Scenario: Interrupt is a stopping error rather than timeout feedback
    When shellbound runs native "interrupt" with setting "1" and command "sleep 3"
    Then shellbound stops with interrupt status 130 and no timeout tool feedback

  Scenario: Configured commands are not bounded by the model shell policy
    When shellbound runs native "configured" with setting "1" and command "printf exact"
    Then shellbound lands with ordinary result "exit status: 0\nexact"
    And shellbound configured commands completed their three-second waits

  Scenario: Document the opt-in and its exclusions
    Then shellbound configuration guidance describes "tool_shell_timeout_seconds", "Shape", "Refine", "probe", "claude-code", "default" and "opt-in"

  Scenario: Amended specification has executable conformance
    When shellbound runs the specification and installed chapter 04 conformance
    Then shellbound conformance passes and includes caller-opt-in coverage
