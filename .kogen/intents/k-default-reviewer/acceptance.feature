Feature: Terra medium reviewer defaults
  Scenario Outline: Built-in and init defaults agree
    When I read reviewer defaults from "<source>"
    Then the reviewer defaults JSON is:
      """
      {"shape":{"Provider":"","Model":"gpt-6.1-sol","Effort":"high"},"build":{"Provider":"","Model":"gpt-6.1-sol","Effort":"medium"},"review":{"Provider":"","Model":"gpt-6.1-terra","Effort":"medium"}}
      """
    Examples:
      | source   |
      | builtin  |
      | template |

  Scenario: Explicit project review wins
    When I read reviewer defaults from "explicit"
    Then the reviewer defaults JSON is:
      """
      {"shape":{"Provider":"","Model":"gpt-6.1-sol","Effort":"high"},"build":{"Provider":"","Model":"gpt-6.1-sol","Effort":"medium"},"review":{"Provider":"chatgpt","Model":"gpt-6.1-sol","Effort":"high"}}
      """
