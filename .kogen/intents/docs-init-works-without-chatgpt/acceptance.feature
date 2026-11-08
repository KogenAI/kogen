Feature: Document that kogen init works without ChatGPT
  Scenario: Guide steps 3 and 4 say discovery works with any signed-in route
    Then docs-init-works-without-chatgpt: step 3 of the getting-started guide contains these phrases
      | discovery works with any signed-in route |
      | kogen provider login chatgpt |
      | printf '%s' "$ANTHROPIC_API_KEY" \| kogen provider login anthropic |
      | printf '%s' "$CLAUDE_CODE_TOKEN" \| kogen provider login claude-code |
    And docs-init-works-without-chatgpt: step 4 of the getting-started guide contains these phrases
      | discovery works with any signed-in route |

  Scenario: Step 4 names the optional hand-written path and the next command
    Then docs-init-works-without-chatgpt: step 4 of the getting-started guide contains these phrases
      | Without ChatGPT is the optional hand-written path |
      | `ok models - shape, build, review ready` means the next command is `kogen intent shape <slug> <request-file>` |

  Scenario: README.md lists the three sign-in routes
    Then docs-init-works-without-chatgpt: "README.md" contains these phrases
      | any one of these routes |
      | kogen provider login chatgpt |
      | printf '%s' "$ANTHROPIC_API_KEY" \| kogen provider login anthropic |
      | printf '%s' "$CLAUDE_CODE_TOKEN" \| kogen provider login claude-code |

  Scenario: packaging/README.md lists the three sign-in routes
    Then docs-init-works-without-chatgpt: "packaging/README.md" contains these phrases
      | any one of these routes |
      | kogen provider login chatgpt |
      | printf '%s' "$ANTHROPIC_API_KEY" \| kogen provider login anthropic |
      | printf '%s' "$CLAUDE_CODE_TOKEN" \| kogen provider login claude-code |

  Scenario: packaging/README.md no longer ties Kogen to a ChatGPT plan
    Then docs-init-works-without-chatgpt: line 3 of "packaging/README.md" is "Kogen takes one requested feature through shaping, building, verifying, reviewing and committing, in your own Git repository."

  Scenario: No file claims that kogen init needs ChatGPT
    Then docs-init-works-without-chatgpt: no file claims that kogen init needs ChatGPT
