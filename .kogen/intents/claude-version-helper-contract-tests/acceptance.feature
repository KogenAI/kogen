Feature: Direct regression tests for Claude Code version helpers
  This adds tests in cli/internal/claudecode/runtime_test.go only. Version and runtime selection stay unchanged.

  Background:
    Given claude-version-helper-contract-tests: the unmodified Claude Code package tests pass

  Scenario: Read just the first version field
    Then claude-version-helper-contract-tests: the package tests reject these wrong results for FirstField
      | arguments                      | expected  | wrong result              |
      | ""                             | ""        | "missing"                 |
      | " \\t\\n"                      | ""        | answer                    |
      | " \\t2.1.300 (Claude Code)\\n" | "2.1.300" | strings.TrimSpace(answer) |

  Scenario: Match the entire pinned version field
    Then claude-version-helper-contract-tests: the package tests reject these wrong results for Pinned
      | arguments                              | expected | wrong result                      |
      | " \\t" + Version + " (Claude Code)\\n" | true     | false                             |
      | ""                                     | false    | true                              |
      | Version + "0 (Claude Code)"            | false    | strings.Contains(answer, Version) |
      | Version + "-beta (Claude Code)"        | false    | strings.Contains(answer, Version) |

  Scenario: Name the path, answer and expected runtime version
    Then claude-version-helper-contract-tests: the package tests reject these wrong results for NotPinnedMessage
      | arguments                                                   | expected                                                                                                       | wrong result                                                                          |
      | "/x/claude", Version + "-beta (Claude Code)", Version       | "Kogen's Claude Code at /x/claude reports " + Version + "-beta (Claude Code), not the pinned " + Version       | "Kogen's Claude Code at " + path + " reports " + answer + ", not the active " + want  |
      | "/x/claude", Version + "-beta (Claude Code)", Version + "0" | "Kogen's Claude Code at /x/claude reports " + Version + "-beta (Claude Code), not the active " + Version + "0" | "Kogen's Claude Code at " + path + " reports " + answer + ", not the pinned " + want  |
      | "/x/claude", Version + "-beta (Claude Code)", Version       | "Kogen's Claude Code at /x/claude reports " + Version + "-beta (Claude Code), not the pinned " + Version       | "Kogen's Claude Code reports " + answer + ", not the pinned " + want                  |
      | "/x/claude", Version + "-beta (Claude Code)", Version + "0" | "Kogen's Claude Code at /x/claude reports " + Version + "-beta (Claude Code), not the active " + Version + "0" | "Kogen's Claude Code at " + path + " reports another version, not the active " + want |
