Feature: Kogen's README and docs are short and task-first
  This feature checks that the README and docs hold concise, accurate, task-first user documentation.

  Scenario: README is short and names install routes, platforms and the agent line
    Then k-docs-concise-task-first: README.md has fewer than 80 lines
    And k-docs-concise-task-first: README.md contains the line 'curl -fsSL https://get.kogen.dev | sh'
    And k-docs-concise-task-first: README.md contains the line 'brew trust kogenai/tap && brew install kogenai/tap/kogen'
    And k-docs-concise-task-first: README.md contains the text 'https://kogen.dev/get-started/'
    And k-docs-concise-task-first: README.md contains the text 'Homebrew 7'
    And k-docs-concise-task-first: README.md contains the text 'macOS arm64'
    And k-docs-concise-task-first: README.md contains the text 'macOS x86-64'
    And k-docs-concise-task-first: README.md contains the text 'Linux x86-64'
    And k-docs-concise-task-first: README.md contains the text 'Linux arm64'
    And k-docs-concise-task-first: README.md contains the text 'make changes through `kogen intent shape`, `approve` and `build`'
    And k-docs-concise-task-first: README.md contains the text 'docs/'
    And k-docs-concise-task-first: README.md contains the text 'spec/'
    And k-docs-concise-task-first: README.md does not contain the text 'brew install KogenAI/tap/kogen'
    And k-docs-concise-task-first: README.md contains the text 'kogen intent build'

  Scenario: README quickstart shows the real first and last outputs
    Then k-docs-concise-task-first: README.md shows 'Initialized Kogen in <path>' inside a fenced block
    And k-docs-concise-task-first: README.md shows 'landed <slug> 03c89ee0 (Build e9acffc6)' inside a fenced block

  Scenario: docs holds only the user documents
    Then k-docs-concise-task-first: docs contains exactly the files 'getting-started.md, configuration.md, troubleshooting.md, testing-rules.md'

  Scenario: testing-rules.md stays unchanged
    Then k-docs-concise-task-first: docs&#47;testing-rules.md is unchanged

  Scenario: getting-started shows real outputs in fenced blocks
    Then k-docs-concise-task-first: docs/getting-started.md has fewer than 150 lines
    And k-docs-concise-task-first: docs/getting-started.md shows 'kogen v0.1.0-dev.62015185 (2026-11-07)' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'provider/login: not signed in; run kogen provider login for a supported provider' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'kogen provider login chatgpt' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'kogen provider list' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'claude-code: token saved (not verified)' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'kogen uninstall' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'Commit: 1eb6a4ca Add Kogen configuration' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'Scenarios: 5 (4 fail now, 1 pass now)' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'Next: kogen intent build <slug>' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md shows 'landed <slug> 03c89ee0 (Build e9acffc6)' inside a fenced block
    And k-docs-concise-task-first: docs/getting-started.md contains the text 'kogen intent shape <slug> <request-file>'
    And k-docs-concise-task-first: docs/getting-started.md does not contain the text 'kogen <version>'
    And k-docs-concise-task-first: docs/getting-started.md contains the text '.kogen/host-id'

  Scenario: configuration is a short reference
    Then k-docs-concise-task-first: docs/configuration.md has fewer than 120 lines
    And k-docs-concise-task-first: docs/configuration.md contains the text '.kogen/project.yaml'
    And k-docs-concise-task-first: docs/configuration.md contains the text '.kogen/models.yaml'
    And k-docs-concise-task-first: docs/configuration.md contains the text '.kogen/local/models.yaml'
    And k-docs-concise-task-first: docs/configuration.md has at least 3 fenced blocks
    And k-docs-concise-task-first: docs/configuration.md has no line over 160 characters
    And k-docs-concise-task-first: docs/configuration.md does not contain the text 'refuses a models: key'

  Scenario: troubleshooting gives message, meaning and next command for every code
    Then k-docs-concise-task-first: docs/troubleshooting.md exists
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'environment/not_a_git_repo: <path>; run git init first'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'environment/git_identity_missing: no Git user.name and user.email; run git config user.name "<name>" and git config user.email "<email>" (global or repository)'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'environment/not_initialized: <root> has no .kogen/project.yaml; run kogen init'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'provider/login: not signed in; run kogen provider login for a supported provider'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'kogen provider login chatgpt'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'candidate/recovery_unsupported'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'candidate/resume_unsupported'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'kogen intent list'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'intent/not_found: Intent does not exist'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'not_project'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'setup_failed'
    And k-docs-concise-task-first: docs/troubleshooting.md contains the text 'go: command not found'

  Scenario: every relative link resolves
    Then k-docs-concise-task-first: every relative link in README.md and docs resolves to an existing file

  Scenario: nothing else in the repository changed
    Then k-docs-concise-task-first: the working tree changes only documentation, spec additions, steps and tests
