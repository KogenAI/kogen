Feature: Batch reviewer rounds and name malformed findings
  The prompt is guidance, not a round cap. All existing review duties remain.
  Research identity: Review: a findings list sent as a JSON string is rejected with feedback that does not name the problem

  Background:
    Given these review-efficiency feedback prefixes:
      | shape | submit_review needs verdict (approve or changes) and a findings list |
      | tool  | invalid verdict:                                                   |

  Scenario: Replace exactly the requested sentence and emit it in a real review
    When I capture review-efficiency instructions from an approving review request
    Then the review-efficiency prompt bytes and emitted instructions match:
      """json
      {
        "originalHash": "39e51da233be9dd2aaaae9ef3d24aa1fcb95421ae54c04360225a5a8c1cd9419",
        "targetHash": "1ab7ff81c6b94254ac71958230859fd9c76ffc15baa25ad2552017cbd11cceb9",
        "schemaHash": "b921e44cb5f52d493169809ee8374164d94fa5071c7c811b41cc416a1476b3d1",
        "oldSentence": "Read other files only to fill a context gap, and batch independent lookups.",
        "paragraph": "Read other files only to fill a context gap. Every request re-sends the whole conversation, so work in a few wide rounds, not one call per turn: issue all pinned-part reads and needed context lookups together in your first tool round; never re-read text already supplied inline or read earlier; then make related repairs together and run your focused probes (stated limits, empty or zero values, error paths) in one combined shell command where possible. Code that proves correct usually needs only three rounds: reads, one probe round, then submit_review. Add a round only when a result raises a new concern or a repair needs checking; after a repair, run the configured fixer and the focused tests together in one command. Never spend a round on a lone lookup or on re-confirming a result you already have."
      }
      """

  Scenario Outline: Preserve the accepted set and explain only field types
    When I observe review-efficiency submissions through "<boundary>":
      | args | accepted | shape | detail |
      | {"verdict":"approve","findings":[]} | true | false | - |
      | {"verdict":"approve","findings":[{"path":"app.txt","line":1,"severity":"note","message":"PRIVATE_REVIEW_MARKER"}]} | true | false | - |
      | {"verdict":"changes","findings":[{"path":"app.txt","line":1,"severity":"blocking","message":"PRIVATE_REVIEW_MARKER"}]} | true | false | - |
      | {"verdict":"approve","findings":"[]"} | false | true | findings must be a JSON array of objects but was a string |
      | {"verdict":"approve","findings":"[{\"path\":\"app.txt\",\"line\":1,\"severity\":\"note\",\"message\":\"PRIVATE_REVIEW_MARKER\"}]"} | false | true | findings must be a JSON array of objects but was a string |
      | {"verdict":"approve"} | false | true | findings must be a JSON array of objects but was missing |
      | {"verdict":"approve","findings":null} | false | true | findings must be a JSON array of objects but was null |
      | {"verdict":"approve","findings":{"private":"PRIVATE_REVIEW_MARKER"}} | false | true | findings must be a JSON array of objects but was an object |
      | {"verdict":"approve","findings":true} | false | true | findings must be a JSON array of objects but was a boolean |
      | {"verdict":"approve","findings":12345} | false | true | findings must be a JSON array of objects but was a number |
      | {"findings":[]} | false | true | verdict must be approve or changes but was missing |
      | {"verdict":null,"findings":[]} | false | true | verdict must be approve or changes but was null |
      | {"verdict":12345,"findings":[]} | false | true | verdict must be approve or changes but was a number |
      | {"verdict":false,"findings":[]} | false | true | verdict must be approve or changes but was a boolean |
      | {"verdict":{"private":"PRIVATE_REVIEW_MARKER"},"findings":[]} | false | true | verdict must be approve or changes but was an object |
      | {"verdict":["PRIVATE_REVIEW_MARKER"],"findings":[]} | false | true | verdict must be approve or changes but was an array |
      | {"verdict":"PRIVATE_REVIEW_MARKER","findings":[]} | false | true | verdict must be approve or changes but was a string with an unsupported value |
      | {} | false | true | verdict must be approve or changes but was missing; findings must be a JSON array of objects but was missing |
      | {"verdict":"PRIVATE_REVIEW_MARKER","findings":"PRIVATE_REVIEW_MARKER"} | false | true | verdict must be approve or changes but was a string with an unsupported value; findings must be a JSON array of objects but was a string |
      | {"verdict":"changes","findings":[]} | false | false | a changes verdict needs at least one blocking finding |
      | {"verdict":"approve","findings":[{"path":"app.txt","line":1,"severity":"blocking","message":"PRIVATE_REVIEW_MARKER"}]} | false | false | an approve verdict cannot have blocking findings |
      | {"verdict":"approve","findings":[{"path":"app.txt","line":1.5,"severity":"note","message":"PRIVATE_REVIEW_MARKER"}]} | false | false | each finding needs path (string), line (integer), severity (blocking or note) and message |
    Then every review-efficiency result matches its table without disclosing "PRIVATE_REVIEW_MARKER"

    Examples:
      | boundary     |
      | direct       |
      | conversation |

  Scenario: A second invalid findings string stops the Build without a commit
    When I repeat this review-efficiency invalid submission twice:
      """json
      {"verdict":"approve","findings":"[{\"path\":\"app.txt\",\"line\":1,\"severity\":\"note\",\"message\":\"PRIVATE_REVIEW_MARKER\"}]"}
      """
    Then the review-efficiency stop has these observations:
      | exit         | 1 |
      | requests     | 2 |
      | head_changed | false |
      | outcome      | review_invalid |
      | detail       | findings must be a JSON array of objects but was a string |
      | stop         | candidate/review_invalid |
      | private      | PRIVATE_REVIEW_MARKER |
