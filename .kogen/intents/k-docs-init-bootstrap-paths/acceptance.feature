Feature: Explain init bootstrap paths
  Scenario Outline: Describe the three states at each task entry
    Then k-docs-init-bootstrap-paths: "<doc>" has a paragraph matching "<pattern>"
    Examples:
      | doc | pattern |
      | README.md | (?i)empty[^.]*configuration.only[^.]*Initial commit |
      | docs/getting-started.md | (?i)empty[^.]*configuration.only[^.]*Initial commit |
      | README.md | (?i)unborn[^.]*uncommitted[^.]*environment/no_commits |
      | docs/getting-started.md | (?i)unborn[^.]*uncommitted[^.]*environment/no_commits |
      | README.md | (?i)committed[^.]*Add Kogen configuration |
      | docs/getting-started.md | (?i)committed[^.]*Add Kogen configuration |
      | README.md | (?i)commit[^.]*generated[^.]*first[^.]*separate[^.]*Add Kogen configuration |
      | docs/getting-started.md | (?i)commit[^.]*generated[^.]*first[^.]*separate[^.]*Add Kogen configuration |

  Scenario Outline: Keep documentation literals aligned with init
    Then k-docs-init-bootstrap-paths: "<doc>" contains init contract literal "<literal>"
    Examples:
      | doc | literal |
      | README.md | Initial commit |
      | README.md | Add Kogen configuration |
      | README.md | environment/no_commits |
      | docs/getting-started.md | Initial commit |
      | docs/getting-started.md | Add Kogen configuration |
      | docs/getting-started.md | environment/no_commits |

  Scenario Outline: Remove the blanket commit prerequisite
    Then k-docs-init-bootstrap-paths: "<doc>" does not require a repository with at least one commit
    Examples:
      | doc |
      | README.md |
      | docs/getting-started.md |
