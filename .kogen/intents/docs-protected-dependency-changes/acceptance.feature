Feature: Update dependencies without weakening project checks

  Scenario: Find the next action after a protected Shape refusal
    Then docs-protected-dependency-changes: "shape/protected_conflict" guidance in Getting Started links to the dependency handoff in Configuration
      | CLI names the files to review |
      | outside Build                 |
      | shape again                   |
    And docs-protected-dependency-changes: "docs/configuration.md" distinguishes Shape refusal from recovery and links to "kogen intent recover <Build id> --output <new directory>"

  Scenario: Distinguish dependency inputs from mixed check definitions
    Then docs-protected-dependency-changes: "docs/configuration.md" explains ordinary dependency work
      | Dependency-only manifests and lockfiles |
      | can change in a Build                   |
      | `go.mod` and `go.sum`                   |
      | not grounds for protection              |
    And docs-protected-dependency-changes: "docs/configuration.md" explains whole-file protection
      | explicitly protected              |
      | whole file cannot change in an ordinary Build |
      | no dependency-only exception      |
      | approval of an Intent does not grant protected-file edit permission |
    And docs-protected-dependency-changes: "docs/configuration.md" explains a mixed manifest
      | `mix.exs` |
      | dependencies |
      | `test` alias |
      | configured `mix test` |
    And docs-protected-dependency-changes: "docs/configuration.md" explains a mixed manifest
      | `package.json` |
      | dependencies |
      | `test` script |
      | configured `npm test` |

  Scenario: Review and verify the exact mixed-file baseline before shaping again
    Then docs-protected-dependency-changes: "docs/configuration.md" gives the baseline handoff in order
      | outside Build |
      | exact dependency and lockfile diff against the current base |
      | existing test definitions protected |
      | fresh checkout |
      | existing checks and any proposed new checks |
      | commit the reviewed change |
      | shape again on the updated base |
      | `kogen intent shape <slug> request.md` |
    And docs-protected-dependency-changes: "docs/configuration.md" reviews a new required check before enabling it
      | new required check |
      | command |
      | actual check configuration |
      | baseline change |
      | verify it before enabling it |
