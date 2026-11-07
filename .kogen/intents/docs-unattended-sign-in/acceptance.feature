Feature: Explain browserless provider sign-in
  # Required command: printf '%s' "$ANTHROPIC_API_KEY" | kogen provider login anthropic
  # Required command: printf '%s' "$CLAUDE_CODE_TOKEN" | kogen provider login claude-code
  Scenario: Step 3 gives agents usable stdin routes
    Then docs-unattended-sign-in: step 3 contains these literal instructions
      | Without a browser (scripts, agents, remote shells) |
      | printf '%s' "$ANTHROPIC_API_KEY" \| kogen provider login anthropic |
      | printf '%s' "$CLAUDE_CODE_TOKEN" \| kogen provider login claude-code |
      | claude setup-token |
    And docs-unattended-sign-in: step 3 explains these requirements
      | ChatGPT requires a browser on the same machine at port 1455 and has no unattended form |
      | A person must supply the secret |
