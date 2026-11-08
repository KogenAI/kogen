Feature: The release archive ships the getting-started guide
  The archive built by package.sh holds the guide and every file it links, its README links the guide and shows the scripted form, and a release check fails when a linked file is missing.

  Scenario: The packaged archive holds the guide and every file it links
    When release-archive-ships-getting-started: I package the checkout with package.sh
    Then release-archive-ships-getting-started: the archive holds these files
      | path                                      |
      | docs/getting-started.md                   |
      | docs/configuration.md                     |
      | docs/testing-rules.md                     |
      | docs/usage.md                             |
      | docs/model-family-qualification.md        |
      | docs/presets/anthropic-only.yaml          |
      | docs/presets/opencode-go-only.yaml        |
      | docs/presets/supergrok-only.yaml          |
      | docs/presets/supergrok-opencode-go.yaml   |
      | docs/presets/three-subscriptions.yaml     |
    And release-archive-ships-getting-started: the archive file "docs/getting-started.md" equals the checkout file "docs/getting-started.md"

  Scenario: The shipped README links the guide and states the scripted form in two lines
    When release-archive-ships-getting-started: I package the checkout with package.sh
    Then release-archive-ships-getting-started: the archive README links "docs/getting-started.md"
    And release-archive-ships-getting-started: the archive README section "Without a terminal" has exactly two lines containing
      | line | text                         |
      | 1    | without a terminal           |
      | 1    | <n>: <letter>                |
      | 1    | standard input               |
      | 1    | kogen intent approve         |
      | 1    | card hash                    |
      | 2    | `0` means ready              |
      | 2    | `5` means needs approval     |
      | 2    | refused                      |

  Scenario: The release check fails when a linked file is missing from the archive
    When release-archive-ships-getting-started: I package the checkout with package.sh
    Then release-archive-ships-getting-started: the release check gives
      | form      | removed                          | exit | output                                                                           |
      | directory | -                                | 0    | archive links ok:                                                                |
      | archive   | -                                | 0    | archive links ok:                                                                |
      | directory | docs/getting-started.md          | 1    | missing docs/getting-started.md (linked from README.md)                          |
      | archive   | docs/getting-started.md          | 1    | missing docs/getting-started.md (linked from README.md)                          |
      | directory | docs/presets/anthropic-only.yaml | 1    | missing docs/presets/anthropic-only.yaml (linked from docs/getting-started.md)   |
      | directory | docs/configuration.md            | 1    | missing docs/configuration.md (linked from docs/getting-started.md)              |
      | directory | docs/usage.md                    | 1    | missing docs/usage.md (linked from docs/configuration.md)                        |

  Scenario: package.sh refuses to publish an archive missing a linked file
    When release-archive-ships-getting-started: I package a checkout copy without "docs/presets/anthropic-only.yaml"
    Then release-archive-ships-getting-started: packaging fails naming "missing docs/presets/anthropic-only.yaml (linked from docs/getting-started.md)" and publishes no archive
