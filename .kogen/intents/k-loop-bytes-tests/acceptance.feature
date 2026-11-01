Feature: Kogen's tests pin Kogen's own request content, not kogen-loop's wording
  The six tests a loop re-pin turned red compare what Kogen itself sends and read the loop's
  text from the pinned loop. Each scratch copy of the working tree carries exactly one
  replacement; the Build's tree and its vendored loop stay unchanged. A contract-preserving
  rewording of the pinned loop's shell tool description keeps the six tests green, while a
  changed sentence of Kogen's own reviewer or builder instructions, or of its finish tool,
  still turns the tests that carry it red.

  Background:
    Given loop-bytes proof makes these scratch copies of the working tree, each with exactly one replacement:
      | copy              | file                                     | old                                                                                              | new                                                                                                       |
      | loop-wording      | cli/third_party/kogen-loop/tools/defs.go | stdin is closed; stdout and stderr are combined.                                                 | Standard input is closed, and standard output and standard error are combined.                            |
      | reviewer-sentence | cli/agent/prompts/reviewer.md            | You do not see the builder's conversation.                                                       | The builder's conversation is not shown to you.                                                           |
      | builder-sentence  | cli/agent/prompts/builder.md             | Do not commit, push, stash, reset or switch branches; Kogen commits after verification and review. | Do not commit, push, stash, reset or switch branches; Kogen makes the one commit after verification and review. |
      | finish-tool       | cli/agent/defs.go                        | Say the implementation is complete.                                                              | State that the implementation is complete.                                                                |
    When loop-bytes proof runs these Go tests in those copies:
      | copy              | package | test                                     |
      | loop-wording      | .       | TestResearchRemovalDefaults              |
      | loop-wording      | ./agent | TestDefinitionsMatchTheElixirDefinitions |
      | loop-wording      | ./build | TestKRevodGatePartsUnchanged             |
      | loop-wording      | ./build | TestNamedFeedbackCompatibility           |
      | loop-wording      | ./build | TestContextExternalNativeBytes           |
      | loop-wording      | ./build | TestKReviewRetryUnchangedValidRequests   |
      | reviewer-sentence | ./build | TestKRevodGatePartsUnchanged             |
      | reviewer-sentence | ./build | TestKReviewRetryUnchangedValidRequests   |
      | reviewer-sentence | ./build | TestContextExternalNativeBytes           |
      | builder-sentence  | ./build | TestNamedFeedbackCompatibility           |
      | builder-sentence  | ./build | TestContextExternalNativeBytes           |
      | finish-tool       | .       | TestResearchRemovalDefaults              |
      | finish-tool       | ./agent | TestDefinitionsMatchTheElixirDefinitions |

  Scenario: A contract-preserving rewording of the loop's shell description keeps the six tests green
    Then loop-bytes proof finds "cli/third_party/kogen-loop" in the working tree matches the digest and file count in "cli/loop-pin.json"
    And loop-bytes proof finds "cli/third_party/kogen-loop" in copy "loop-wording" does not match the digest in "cli/loop-pin.json"
    And loop-bytes proof observed these Go tests run once and pass in copy "loop-wording":
      | package | test                                     |
      | .       | TestResearchRemovalDefaults              |
      | ./agent | TestDefinitionsMatchTheElixirDefinitions |
      | ./build | TestKRevodGatePartsUnchanged             |
      | ./build | TestNamedFeedbackCompatibility           |
      | ./build | TestContextExternalNativeBytes           |
      | ./build | TestKReviewRetryUnchangedValidRequests   |

  Scenario: A changed sentence of Kogen's reviewer instructions still fails the review request tests
    Then loop-bytes proof observed these Go tests run once and pass in copy "loop-wording" and run once and fail in copy "reviewer-sentence":
      | package | test                                   |
      | ./build | TestKRevodGatePartsUnchanged           |
      | ./build | TestKReviewRetryUnchangedValidRequests |
      | ./build | TestContextExternalNativeBytes         |

  Scenario: A changed sentence of Kogen's builder instructions still fails the build request tests
    Then loop-bytes proof observed these Go tests run once and pass in copy "loop-wording" and run once and fail in copy "builder-sentence":
      | package | test                           |
      | ./build | TestNamedFeedbackCompatibility |
      | ./build | TestContextExternalNativeBytes |

  Scenario: A changed description of Kogen's finish tool still fails the definition and plain request tests
    Then loop-bytes proof observed these Go tests run once and pass in copy "loop-wording" and run once and fail in copy "finish-tool":
      | package | test                                     |
      | .       | TestResearchRemovalDefaults              |
      | ./agent | TestDefinitionsMatchTheElixirDefinitions |
