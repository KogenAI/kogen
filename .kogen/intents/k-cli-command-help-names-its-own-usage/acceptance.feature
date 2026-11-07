Feature: Command-specific help
  # The CLI binary is kogen. Required invocations expanded by the examples:
  # kogen init --help
  # kogen uninstall --help
  # kogen version --help
  # kogen context --help
  # kogen intent shape --help
  # kogen intent approve --help
  # kogen intent build --help
  # kogen provider --help
  # kogen intent --help
  # kogen nonsense
  Background:
    Given k-cli-command-help-names-its-own-usage: a compiled CLI and an isolated non-Git directory

  Scenario Outline: Each public path has its own help
    When k-cli-command-help-names-its-own-usage: I run "<command> <flag>"
    Then k-cli-command-help-names-its-own-usage: the exit status is 0
    And k-cli-command-help-names-its-own-usage: the first line names "<command>"
    And k-cli-command-help-names-its-own-usage: the help contains "Purpose:"
    And k-cli-command-help-names-its-own-usage: the help contains "Arguments:"
    And k-cli-command-help-names-its-own-usage: the help contains "Options:"
    And k-cli-command-help-names-its-own-usage: the help contains "Prerequisites:"
    And k-cli-command-help-names-its-own-usage: the help contains "Changes:"
    And k-cli-command-help-names-its-own-usage: the help contains "Exit codes:"
    And k-cli-command-help-names-its-own-usage: the help contains "Next:"
    And k-cli-command-help-names-its-own-usage: the sandbox is unchanged
    Examples:
      | command | flag |
      | init | --help |
      | uninstall | --help |
      | version | --help |
      | context | --help |
      | intent shape | --help |
      | intent approve | --help |
      | intent build | --help |
      | intent refine | --help |
      | intent recover | --help |
      | intent resume | --help |
      | intent list | --help |
      | intent usage | --help |
      | intent inspect | --help |
      | intent preflight | --help |
      | intent | --help |
      | provider | --help |
      | provider login | --help |
      | provider list | --help |
      | completion | --help |
      | completion zsh | --help |
      | init | -h |
      | uninstall | -h |
      | version | -h |
      | context | -h |
      | intent shape | -h |
      | intent approve | -h |
      | intent build | -h |
      | intent refine | -h |
      | intent recover | -h |
      | intent resume | -h |
      | intent list | -h |
      | intent usage | -h |
      | intent inspect | -h |
      | intent preflight | -h |
      | intent | -h |
      | provider | -h |
      | provider login | -h |
      | provider list | -h |
      | completion | -h |
      | completion zsh | -h |

  Scenario Outline: Required operational disclosures
    When k-cli-command-help-names-its-own-usage: I run "<command> --help"
    Then k-cli-command-help-names-its-own-usage: the help contains "<text>"
    Examples:
      | command | text |
      | init | clean |
      | init | committed |
      | init | Git identity |
      | init | login |
      | init | .kogen/project.yaml |
      | init | .kogen/models.yaml |
      | init | commit |
      | intent build | commit |

  Scenario Outline: Global command list is retained
    When k-cli-command-help-names-its-own-usage: I run "<arguments>"
    Then k-cli-command-help-names-its-own-usage: the exit status is <status>
    And k-cli-command-help-names-its-own-usage: the global command list is printed
    And k-cli-command-help-names-its-own-usage: the sandbox is unchanged
    Examples:
      | arguments | status |
      | help | 0 |
      | nonsense | 2 |
      | help --help | 0 |
      | help -h | 0 |

  Scenario Outline: Help cannot hide an unknown flag
    When k-cli-command-help-names-its-own-usage: I run "<command> <flags>"
    Then k-cli-command-help-names-its-own-usage: the unknown flag is refused
    Examples:
      | command | flags |
      | init | --not-a-kogen-option |
      | init | --not-a-kogen-option --help |
      | init | --help --not-a-kogen-option |
      | uninstall | --not-a-kogen-option --help |
      | version | --not-a-kogen-option --help |
      | context | --not-a-kogen-option --help |
      | intent shape | --not-a-kogen-option --help |
      | intent refine | --not-a-kogen-option --help |
      | intent approve | --not-a-kogen-option --help |
      | intent build | --not-a-kogen-option --help |
      | intent resume | --not-a-kogen-option --help |
      | intent recover | --not-a-kogen-option --help |
      | intent list | --not-a-kogen-option --help |
      | intent usage | --not-a-kogen-option --help |
      | intent inspect | --not-a-kogen-option --help |
      | intent preflight | --not-a-kogen-option --help |
      | provider | --not-a-kogen-option --help |
      | provider login | --not-a-kogen-option --help |
      | provider list | --not-a-kogen-option --help |
      | intent | --not-a-kogen-option --help |
      | completion | --not-a-kogen-option --help |
      | completion zsh | --not-a-kogen-option --help |
