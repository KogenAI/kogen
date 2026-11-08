Feature: Correct the init prerequisite in the configuration guide
  Scenario: The configuration guide says init discovery works without ChatGPT
    Then docs-config-init-without-chatgpt: "docs/configuration.md" contains these phrases
      | Automatic command discovery with bare `kogen init` works with any supported signed-in discovery route, including Claude Code and Anthropic, and does not require a ChatGPT account |
      | Bare init discovery works with any supported signed-in discovery route, including Claude Code and Anthropic, and does not require a ChatGPT account |

  Scenario: The surrounding role-validation guidance is preserved
    Then docs-config-init-without-chatgpt: "docs/configuration.md" contains these phrases
      | This repository retains its existing ChatGPT bootstrap lineup. |
      | Shape checks its role, Refine checks Shape, and Build/resume checks Build and Review; unused providers need no login. |
      | No preset command, init provider selector or automatic router is added. |

  Scenario: The old ChatGPT-only claim is gone
    Then docs-config-init-without-chatgpt: "docs/configuration.md" has none of the stale init claims
