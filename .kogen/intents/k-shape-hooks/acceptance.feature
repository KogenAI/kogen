Feature: Shape cannot plant trusted Git execution state
  Scenario Outline: Refuse persistent Git execution-state mutations
    When the hook custody Shape fixture performs "<mutation>"
    Then hook custody refuses naming "<name>" without publishing or executing a hook
    Examples:
      | mutation       | name           |
      | add            | commit-msg     |
      | remove         | commit-msg     |
      | modify         | commit-msg     |
      | mode           | commit-msg     |
      | symlink-target | commit-msg     |
      | symlink-path   | commit-msg     |
      | hooks-path     | core.hooksPath |
      | fsmonitor      | core.fsmonitor |
      | filter         | filter.audit.clean |
      | global-include | core.sshCommand |

  Scenario: Honest read-only Shape remains usable
    When the hook custody Shape fixture performs "honest"
    Then hook custody publishes unchanged without executing a hook
