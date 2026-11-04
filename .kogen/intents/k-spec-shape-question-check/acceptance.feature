Feature: Fake shapers answer Shape's question check and a refused question is specified

  Scenario: The shaping chapter specifies a refused question and the progress line of an asked one
    Given k-spec-shape-question-check: the specification file "spec/features/02-shaping.feature"
    Then k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      @SHP-6 @SHP-12
      Scenario: A question the check does not class as UI/UX goes back to the shaper and is not asked
        Given the fake ChatGPT server plays script "shape-asks-technical-then-writes"
        When the caller runs "kogen intent shape is-even -" with stdin:
          """
          Add calc.is_even(n).
          """
        Then the exit code is 0
        And stdout does not contain "Questions for"
        And stderr contains "kogen: checking the questions"
        And stderr contains "kogen: question check response input=100 cached=5 output=20 reasoning=10 wall_ms="
        And request 2 contains "Question check: 1 of 1 question(s) are not UI/UX choices left to the user; nothing was asked."
        And request 2 contains "- question 1 (technical): Which protocol and endpoint should the integration use?"
        And stdout contains "shape {model}/{effort} input=500 cached=25 output=100 reasoning=50 wall_ms="
        And the file ".kogen/intents/is-even/intent.md" contains "(evidence: README.md) (source: request)"
        And the fake ChatGPT server received 3 requests
      ```
    And k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      Scenario: An open UI/UX choice becomes a numbered question and nothing is written
        Given the fake ChatGPT server plays script "shape-asks-one"
        When the caller runs "kogen intent shape is-even -" with stdin:
          """
          Add calc.is_even(n) and show its result to the user; choose the visual presentation.
          """
        Then the exit code is 5
        And request 1 contains "material UI/UX"
        And stderr contains "kogen: checking the questions"
        And stdout is:
      ```

  Scenario: The shaping prose describes the question check and an asked UI/UX example
    Given k-spec-shape-question-check: the specification file "spec/prose/02-shaping.md"
    Then k-spec-shape-question-check: it does not contain "Do not classify question text."
    And k-spec-shape-question-check: it does not contain "1. What should is_even do with a non-integer?"
    And k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      1. How should the result be presented to the user?
         a) show a text label (recommended)
         b) show an icon
      ```
    And k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      `kind` is optional. Omitted kind and `kind` `product` keep today's printer and exit 5. `kind` `handoff` uses that printer and, after `Questions for <slug>:`, prints exactly `This question is an authentication or security handoff, not a design choice.` Persist kind and print that line again for a pending handoff. Any other explicit kind, including `engineering`, rejects the whole submission with exactly `questions: decide technical questions inside shaping; only kind product or handoff may reach the caller`, prints no questions, writes no Intent, and counts as invalid. Kogen's own code does not classify question text; the question check below does.
      ```
    And k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      Every questions submission that passes validation, native and `executor: claude-code`, then goes to one question check before anything is asked or stored. Native: one fresh read-only request on the shape role and route with its own cache identity, whose only tool is `submit_question_check` (progress `kogen: checking the questions`, then `kogen: question check response <usage> wall_ms=<n>`). `executor: claude-code`: one fresh read-only session (`executor-question-<n>`) whose structured result has the same schema. Its input is the slug, the request, the earlier questions with their answers (`none` when there are none) and the numbered questions with their options. The only valid answer is exactly one `submit_question_check` call (external: one JSON object) of the form `{"items":[{"number":1,"class":"ui_ux","why":"<one short reason>"}]}` with one item for each question 1 to N, where `class` is one of `ui_ux`, `handoff`, `answered`, `technical`, `product_policy`, `environment` or `repository_fact`. Any other answer stops Shape with `shape/question_check_invalid: the question check answer is not a valid submit_question_check payload (<why>); nothing was asked` (exit 1). When every item is `ui_ux` or `handoff`, the questions reach the caller as SHP-6 describes. Otherwise none of them is asked or stored: the shaper's feedback begins `Question check: <k> of <N> question(s) are not UI/UX choices left to the user; nothing was asked.` and lists each refused question as `- question <n> (<class>): <question> | why: <why> | <instruction>`, and the shaper decides those questions itself and records its Decisions. Such a refusal is an invalid submission (SHP-4) with gate `question_check`. A refusal of only `environment` questions that repeats, or that comes at the last allowed submission, ends Shape with `environment/shape_environment: shaping cannot go on without something only your environment can provide; nothing was asked or published` (exit 3). Each check records one `question_check` event (`items`, `asked`, `refused`), and its tokens (native) or rounds (`executor: claude-code`) join the Shape usage line.
      ```

  Scenario: The step vocabulary documents the fake shapers' question check answers and the refusal script
    Given k-spec-shape-question-check: the specification file "spec/features/STEPS.md"
    Then k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      Shape's question check (SHP-6) is answered apart from the script and is not among the requests the scenarios number or count: a request whose tools include `submit_question_check` gets one `submit_question_check` call with one item for each question, each of class `handoff` when the request text contains `Sign in to the provider`, `technical` when it contains `Which protocol and endpoint`, and `ui_ux` otherwise.
      ```
    And k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      | `shape-asks-technical-then-writes` | submits one question without `kind` whose text is `Which protocol and endpoint should the integration use?` (options `HTTP JSON`, recommended, and `gRPC`); after the question check refuses it, reads `README.md` and submits `is-even` with the added Decision `- No protocol or endpoint is involved; calc.is_even is a local function. (evidence: README.md) (source: request)` |
      ```
    And k-spec-shape-question-check: it contains, ignoring whitespace:
      ```
      Shape's question check (a `--json-schema` whose properties include `items`) is answered apart from the script, its counters and sessions: the question `How should the result be presented to the user?` gets one `ui_ux` item.
      ```

  Scenario: Asked, answered, handoff and refused questions all play through the deterministic suite
    When k-spec-shape-question-check: these specification scenarios run through the deterministic acceptance suite:
      | file                                          | title                                                                                 |
      | spec/features/01-project-setup.feature        | Init configures a Node project with its existing runner and a check the model found   |
      | spec/features/01-project-setup.feature        | Kogen data stays ignored and AGENTS.md never reaches a model                          |
      | spec/features/02-shaping.feature              | An open UI/UX choice becomes a numbered question and nothing is written               |
      | spec/features/02-shaping.feature              | Answers continue shaping and the decision records its source                          |
      | spec/features/02-shaping.feature              | All recommended answers continue shaping                                              |
      | spec/features/02-shaping.feature              | Pending questions reject input the caller cannot use                                  |
      | spec/features/02-shaping.feature              | Missing answers are asked again without a model request                               |
      | spec/features/02-shaping.feature              | An engineering question does not reach the caller                                     |
      | spec/features/02-shaping.feature              | An authentication handoff still reaches the caller                                    |
      | spec/features/02-shaping.feature              | A question the check does not class as UI/UX goes back to the shaper and is not asked |
      | spec/features/08-chatgpt.feature              | Empty final metadata preserves complete streamed tools                                |
      | spec/features/claude-code-full-lineup.feature | Shape questions retain numbered CLI answers and start a fresh subsequent session      |
    Then k-spec-shape-question-check: exactly 13 scenario results exist and every step and hook of each passed
