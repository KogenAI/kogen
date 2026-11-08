Feature: Release installation is discoverable before source builds

  Scenario Outline: Copy-paste installer commands lead both install sections
    Then docs-prerelease-install-command-first: the first shell command in "<file>" is "curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh"
    Examples:
      | file |
      | README.md |
      | docs/getting-started.md |

  Scenario: Chosen-tag commands are copy-pasteable
    Then docs-prerelease-install-command-first: install section in "README.md" contains "curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh -s -- --version <tag>"
    Then docs-prerelease-install-command-first: install section in "docs/getting-started.md" contains "curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh -s -- --version <tag>"

  Scenario Outline: Both install sections contain required instructions
    Then docs-prerelease-install-command-first: install section in "<file>" contains "<text>"
    Examples:
      | file | text |
      | README.md | darwin-arm64 |
      | README.md | darwin-x86_64 |
      | README.md | linux-x86_64 |
      | README.md | linux-arm64 |
      | docs/getting-started.md | darwin-arm64 |
      | docs/getting-started.md | darwin-x86_64 |
      | docs/getting-started.md | linux-x86_64 |
      | docs/getting-started.md | linux-arm64 |
      | README.md | Add to PATH |
      | docs/getting-started.md | Add to PATH |
      | README.md | ~/.local/bin |
      | docs/getting-started.md | ~/.local/bin |
      | README.md | contributor |
      | docs/getting-started.md | contributor |
      | README.md | https://github.com/KogenAI/kogen/releases |
      | docs/getting-started.md | https://github.com/KogenAI/kogen/releases |

  Scenario Outline: Source instructions follow the release commands
    Then docs-prerelease-install-command-first: in "<file>" the text "--version" precedes "sh packaging/package.sh"
    Examples:
      | file |
      | README.md |
      | docs/getting-started.md |
