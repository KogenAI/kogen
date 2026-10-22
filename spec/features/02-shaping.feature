# SHP-8/SHP-11: stable successful shaping and published refinement evidence is reusable
# for the version 3 Snapshot candidate tree, full protected baseline hash, declarations and HEAD; failed readiness is never reused.
Feature: Shaping
  A request becomes a ready Intent (prose, Gherkin with step files, Quint
  when needed), or numbered questions about open UI/UX choices.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT

  @SHP-8 @SHP-10 @AUT-1
  Scenario: Declared local rejection cannot be waived by unchanged product-red acknowledgment
    Given the fake ChatGPT server plays script "shape-declared-rejection"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add the existing is-even request and qualify the declared local route control.
      """
    Then the exit code is 0
    And request 2 contains "local-route/support"
    And request 3 contains "local-route/support"
    And request 4 contains "Readiness observations"
    And the fake ChatGPT server received 4 requests
    And the file ".kogen/local/readiness/is-even.json" contains "feasibility"
    And the file ".kogen/local/readiness/is-even.json" contains "explicit rejection"
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 5
    And stdout contains "Readiness observations"

  @SHP-8 @AUT-1 @model:shaping
  Scenario: The final shaper repairs observed fixture failure then acknowledges legitimate product red
    Given the fake ChatGPT server plays script "shape-observed-repair"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add the existing is-even request; inspect actual baseline observations before finishing.
      """
    Then the exit code is 0
    And request 2 contains "unique fixture failure observation"
    And request 3 contains "Readiness observations"
    And stdout contains "3 fail now"
    And the fake ChatGPT server received 3 requests
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 5
    And stdout contains "Readiness observations"
    And stdout contains "Acceptance exit: 1"
    And stdout contains "Evidence: .kogen/local/readiness/is-even.json"

  @SHP-4 @SHP-8 @model:shaping
  Scenario: A narrow shaping correction retains earlier feature and step proposals
    Given the fake ChatGPT server plays script "shape-narrow-retry"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add the existing is-even request and keep settled artifacts when correcting lint.
      """
    Then the exit code is 0
    And request 2 contains "decision has no source"
    And request 3 contains "Readiness observations"
    And stdout contains "3 fail now"
    And the file "features/steps/is_even_steps.js" contains "Given"
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And the fake ChatGPT server received 3 requests

  @SHP-11 @CLI-1 @model:shaping
  Scenario: A targeted correction reuses exact original evidence and still requires approval
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "refine-title"
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Clarify the existing title only.
      """
    Then the exit code is 0
    And stdout contains "refined is-even"
    And the file ".kogen/intents/is-even/intent.md" contains "# Clarify the is-even helper"
    And the file ".kogen/intents/is-even/acceptance.feature" is unchanged
    And the file "features/steps/is_even_steps.js" is unchanged
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And request 1 offers exactly the tools "read_file, list_files, search_text, probe, documentation, submit_refinement"
    And the original refinement readiness receipt has status "hit"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 5
    And stdout contains "intent/not_approved"

  @SHP-11 @model:shaping
  Scenario: A narrow lint correction retains earlier proposed artifact edits in the same run
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "refine-narrow-retry"
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Correct the existing title and feature heading; retain both changes when fixing lint.
      """
    Then the exit code is 0
    And stdout contains "refined is-even"
    And the file ".kogen/intents/is-even/intent.md" contains "# Clarify the is-even helper"
    And the file ".kogen/intents/is-even/acceptance.feature" contains "Feature: Corrected is_even"
    And the file "features/steps/is_even_steps.js" is unchanged
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And request 2 contains "decision has no source"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 5
    And stdout contains "intent/not_approved"

  @SHP-11 @AUT-2 @model:shaping
  Scenario: Correcting an approved package revokes approval and requires a fresh exact approval
    Given the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "refine-title"
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Clarify the existing title only.
      """
    Then the exit code is 0
    And stdout contains "refined is-even"
    And the file ".kogen/intents/is-even/intent.md" contains "# Clarify the is-even helper"
    And the file ".kogen/intents/is-even/acceptance.feature" is unchanged
    And the file "features/steps/is_even_steps.js" is unchanged
    And the file ".kogen/local/approvals/is-even.json" does not exist
    When the caller runs "kogen intent build is-even"
    Then the exit code is 5
    And stdout contains "intent/not_approved"
    When the caller approves "is-even" with the hash from its review card
    Then the exit code is 0
    And stdout contains "approved is-even"

  @SHP-11 @model:shaping
  Scenario: An unsupported correction preserves the ready draft
    Given the Intent "is-even" from fixture "is-even" is shaped
    And the fake ChatGPT server plays script "refine-constraint"
    When the caller refines "is-even" with its current baseline and stdin:
      """
      Add a new step file to this draft.
      """
    Then the exit code is 1
    And stdout contains "shape/refinement_constraint"
    And stdout contains "This correction needs a new step file"
    And the file ".kogen/intents/is-even/intent.md" is unchanged
    And the file ".kogen/intents/is-even/acceptance.feature" is unchanged
    And the file ".kogen/local/approvals/is-even.json" does not exist

  @SHP-1 @SHP-3 @SHP-4 @SHP-8 @SET-6 @SET-9
  Scenario: A complete request from stdin becomes a ready Intent and nothing is approved
    Given the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And stderr matches "kogen: shaping [(]request 1, [0-9]+ s[)]"
    And stdout is:
      """
      Intent: {abs:.kogen/intents/is-even/intent.md}
      Acceptance test: {abs:.kogen/intents/is-even/acceptance.feature}
      Step files: features/steps/is_even_steps.js (new)
      Model: not applicable — a pure function without state
      Scenarios: 3 (3 fail now, 0 pass now)
      shape {model}/{effort} input={n} cached={n} output={n} reasoning={n} wall_ms={n}
      Next: kogen intent approve is-even
      """
    And request 1 contains "Add calc.is_even(n). Non-integers raise TypeError."
    And request 1 has index-first source navigation for "features/steps/calc_steps.js"
    And request 1 contains "Use the narrowest test that exercises the rule"
    And request 1 contains "Existing code and tests are evidence of current behavior"
    And no Kogen process had the request text in its arguments
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And HEAD is unchanged

  @SHP-1
  Scenario Outline: Unusable input is refused before any model request
    When the caller runs "<command>" with stdin:
      """
      <stdin>
      """
    Then the exit code is 2
    And stdout is:
      """
      <line>
      """
    And the fake ChatGPT server received 0 requests

    Examples:
      | command                               | stdin | line                                                                      |
      | kogen intent shape is-even -          |       | intent/request_unavailable: stdin: empty                                  |
      | kogen intent shape is-even missing.md | x     | intent/request_unavailable: {abs:missing.md}: not found                   |
      | kogen intent shape Is_Even -          | x     | intent/invalid_slug: Slug must be 3 to 48 characters and use lowercase letters, digits and dashes. |

  @SHP-1
  Scenario: An untracked request file inside the project is called out
    Given the fake ChatGPT server plays script "shape-ready-is-even"
    And the file "request.md" is changed outside Kogen
    When the caller runs "kogen intent shape is-even request.md"
    Then the exit code is 0
    And stdout contains "note: request.md is untracked; commit or move it before kogen intent build"

  @SHP-2
  Scenario Outline: Shaping refuses what it cannot shape
    Given <condition>
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is <exit>
    And stdout contains "<line>"
    And the fake ChatGPT server received 0 requests

    Examples:
      | condition                                                     | exit | line                                                                         |
      | the project config sets "commands.acceptance.run" to "null"   | 3    | environment/acceptance_unconfigured: set commands.acceptance in .kogen/project.yaml |
      | the project config sets "commands.acceptance.steps_dir" to "null" | 3 | environment/acceptance_unconfigured: set commands.acceptance in .kogen/project.yaml |
      | the Intent "is-even" from fixture "is-even" is shaped         | 5    | intent/exists: is-even is already shaped                                     |

  @SHP-3 @SHP-4 @SHP-7
  Scenario: A required protected edit is reported without creating an Intent or approval
    Given the fake ChatGPT server plays script "shape-protected-conflict"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Change the protected check definition.
      """
    Then the exit code is 1
    And stdout contains "shape/protected_conflict: required edits touch protected files: .style.cfg"
    And stdout contains "the requested check definition must change"
    And stdout contains "Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override."
    And request 1 contains "blocked"
    And request 1 contains "configured protect patterns"
    And request 1 contains "paths currently matched by those patterns"
    And request 1 contains "automatic baseline"
    And request 1 contains "Approval freezes this baseline"
    And request 1 offers exactly the tools "read_file, view_image, list_files, search_text, probe, documentation, submit"
    And the file ".kogen/intents/is-even/intent.md" does not exist
    And the file ".kogen/local/approvals/is-even.json" does not exist
    And the fake ChatGPT server received 1 request

  @SHP-4
  Scenario: Three invalid submissions in a row stop shaping and write nothing
    Given the fake ChatGPT server plays script "shape-invalid-three-times"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 1
    And stdout contains "shape/invalid_output: the shaper's output was not a valid Intent after 3 attempts"
    And the fake ChatGPT server received 3 requests
    And the folder ".kogen/intents/is-even" does not exist

  @SHP-4 @AUT-1
  Scenario: Shaping may edit an existing step file, which the caller reviews before approval
    Given the fake ChatGPT server plays script "shape-edits-existing-step-file"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    And the path "features/steps/calc_steps.js" has uncommitted changes
    When the caller runs "kogen intent approve is-even"
    Then stdout contains "  - features/steps/calc_steps.js"

  @SHP-5
  Scenario Outline: Intent rules
    Given the Intent "is-even" from fixture "<fixture>" is shaped
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 1
    And stdout contains "<message>"

    Examples:
      | fixture                | message                                              |
      | is-even-title-period   | title: the title must not end with a period          |
      | is-even-unsourced      | decisions: a decision has no source                  |
      | is-even-skip-tag       | acceptance: scenario Odd numbers is tagged @skip     |
      | is-even-broken-gherkin | acceptance.feature line 7:                           |
      | is-even-no-tests       | tests: the ## Tests section is missing or empty      |

  @SHP-6 @model:shaping
  Scenario: An open UI/UX choice becomes a numbered question and nothing is written
    Given the fake ChatGPT server plays script "shape-asks-one"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And request 1 contains "material UI/UX"
    And stdout is:
      """
      Questions for is-even:
      1. What should is_even do with a non-integer?
         a) raise TypeError (recommended)
         b) return False
      Answer one per line as <n>: <letter or your words>, e.g. printf '1: a\n' | kogen intent shape is-even -
      Or enter all: recommended to use every question's recommended option.
      """
    And the folder ".kogen/intents/is-even" does not exist

  @SHP-6 @SHP-7 @model:shaping
  Scenario: Answers continue shaping and the decision records its source
    Given the fake ChatGPT server plays script "shape-asks-one-then-writes"
    And the caller ran "kogen intent shape is-even -" with stdin "Add calc.is_even(n)."
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      1: a
      """
    Then the exit code is 0
    And request 2 contains "What should is_even do with a non-integer?"
    And request 2 contains "1: a"
    And the file ".kogen/intents/is-even/intent.md" contains "(source: answer 1)"
    And the file ".kogen/local/approvals/is-even.json" does not exist

  @SHP-6 @SHP-7 @model:shaping
  Scenario: All recommended answers continue shaping
    Given the fake ChatGPT server plays script "shape-asks-two-then-writes"
    And the caller ran "kogen intent shape is-even -" with stdin "Add calc.is_even(n)."
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      all: recommended
      """
    Then the exit code is 0
    And request 2 contains "1: a"
    And request 2 contains "2: a"
    And the file ".kogen/intents/is-even/intent.md" contains "(source: answer 1)"
    And the file ".kogen/intents/is-even/intent.md" contains "(source: answer 2)"

  @SHP-6
  Scenario Outline: Pending questions reject input the caller cannot use
    Given the fake ChatGPT server plays script "shape-asks-one"
    And the caller ran "kogen intent shape is-even -" with stdin "Add calc.is_even(n)."
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      <answer>
      """
    Then the exit code is 2
    And stdout contains "<line>"
    And the fake ChatGPT server received 1 request

    Examples:
      | answer        | line                                                                                       |
      | not an answer | intent/answers_invalid: expected one or more lines as <n>: <letter or your words> (or all: recommended) |
      | 1: c          | intent/answer_option_invalid: question 1 has no option c                                  |

  @SHP-6
  Scenario: Missing answers are asked again without a model request
    Given the fake ChatGPT server plays script "shape-asks-two"
    And the caller ran "kogen intent shape is-even -" with stdin "Add calc.is_even(n)."
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      1: a
      """
    Then the exit code is 5
    And stdout contains "2. "
    And the fake ChatGPT server received 1 request

  @SHP-4 @SHP-8 @VER-12
  Scenario Outline: An undefined step goes back to the shaper even after an assertion failed
    Given the fake ChatGPT server plays script "<script>"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 1
    And the fake ChatGPT server received 3 requests
    And stdout contains "intent/not_ready: the Intent is not ready to build"
    And stdout contains "  acceptance.feature line <line>: undefined step: When the caller doubles 4"
    And the file ".kogen/intents/is-even/acceptance.feature" exists
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 1
    And stdout contains "intent/not_ready: the Intent is not ready to build"
    And the file ".kogen/local/approvals/is-even.json" does not exist

    Examples:
      | script                         | line |
      | shape-undefined-step           | 12   |
      | shape-failed-and-undefined-step | 14   |

  @SHP-4 @SHP-8 @VER-5 @VER-12
  Scenario: A failing Quint invariant goes back to the shaper; after the third failure the Intent is not ready
    Given the fake ChatGPT server plays script "shape-failing-invariant"
    When the caller runs "kogen intent shape counter -" with stdin:
      """
      Add a bounded counter.
      """
    Then the exit code is 1
    And the fake ChatGPT server received 3 requests
    And stdout contains "  model.qnt: invariant NeverNegative violated (seed 7)"
    And the file ".kogen/intents/counter/model.qnt" exists

  @SHP-4 @SHP-6
  Scenario: After a not-ready attempt the shaper may ask a question; the files of that attempt stay
    Given the fake ChatGPT server plays script "shape-not-ready-then-asks"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And stdout contains "Questions for is-even:"
    And the file ".kogen/intents/is-even/acceptance.feature" exists
    And the file ".kogen/local/approvals/is-even.json" does not exist

  @SHP-9
  Scenario: A usage limit stops shaping and writes nothing
    Given the fake ChatGPT server plays script "usage-limit"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 4
    And stdout is:
      """
      provider/usage_limit: ChatGPT usage limit reached; it resets at 2030-01-01T00:00:00Z
        provider failure: {"code":"subscription_sharing_usage_limit_exceeded","http_status":429}
      shape/provider_failed: shaping stopped on a provider error that retrying cannot fix; the failed request wrote no files. Fix the account, then rerun kogen intent shape is-even - with the original request on stdin (or the same answers if questions are pending).
      """
    And the folder ".kogen/intents/is-even" does not exist

  @SHP-10 @SHP-5
  Scenario: A feasibility probe runs in a scratch copy, its result is recorded, and the project stays untouched
    Given the fake ChatGPT server plays script "shape-probes-then-writes"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n). Non-integers raise TypeError.
      """
    Then the exit code is 0
    And the tool result for "probe python3 -c 'print(1.5 % 2)'" contains "1.5"
    And request 1 contains "mise trust"
    And the probe ran outside the project folder
    And the file ".kogen/intents/is-even/intent.md" contains "## Feasibility"
    And the file ".kogen/intents/is-even/intent.md" contains "(probe 1: exit 0"
    And the working tree has no changes outside the Intent's files
    And no probe scratch folder is left behind

  @SHP-10
  Scenario: The five-minute probe policy produces a real timeout and cleanup through a contracted-deadline driver
    Given the fake ChatGPT server plays script "shape-probe-hangs-then-writes"
    When the installed core shapes "is-even" through the contracted-deadline driver with stdin:
      """
      Add calc.is_even(n).
      """
    Then the deadline driver verified the five-minute policy and real timeout cleanup at 200 milliseconds
    And the tool result for "probe sleep 600" contains "timed_out: true"
    And the file ".kogen/intents/is-even/intent.md" contains "## Feasibility"
    And no probe scratch folder is left behind
    And the exit code is 0

  @SHP-2 @LOOP-12
  Scenario: An acceptance command that does not start stops shaping before any model request
    Given the project config sets "commands.acceptance.run" to "exit 7"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 3
    And stdout contains "environment/acceptance_unavailable: the runner check failed with status 7; fix commands.acceptance.run in .kogen/project.yaml"
    And the fake ChatGPT server received 0 requests

  @SET-7 @SHP-2
  Scenario: Warm preparation and clean readiness run setup separately and the unchanged card reuses proof
    Given readiness setup records executions outside the checkout
    And the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    When the caller runs "kogen intent approve is-even"
    Then the exit code is 5
    And readiness has executed 2 times

  @SHP-2 @LOOP-12
  Scenario: A check written as a subshell passes the tool check before shaping
    Given the project config sets "commands.checks" to "[{name: unit, run: '(cd tests && python3 -m unittest discover -s . -t ..)'}, {name: grouped, run: '{ python3 --version; }'}]"
    And the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0

  @SHP-4 @SET-8
  Scenario: Shaping formats the files it writes with the project's fixers and leaves other files alone
    Given the project config sets "commands.fix" to "['f=features/steps/is_even_steps.js; if [ -f $f ]; then grep -q formatted $f || echo // formatted >> $f; fi; grep -q formatted README.md || echo formatted >> README.md']"
    And the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    And stderr contains "kogen: running fix-1"
    And the file "features/steps/is_even_steps.js" contains "// formatted"
    And the file "README.md" is unchanged

  @SHP-12
  Scenario: The shaping request requires technical discovery
    Given the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    And request 1 contains "Shape owns discovery and settlement of material technical questions."
    And request 1 contains "A trivial feature with no material technical uncertainty needs no probe, no sweep and no paid provider research."

  @SHP-12
  Scenario: A files submission without repository inspection is rejected
    Given the fake ChatGPT server plays script "shape-uninspected-submit"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 1
    And stdout contains "shape/invalid_output: the shaper's output was not a valid Intent after 3 attempts"
    And stdout contains "shape/uninspected: inspect the relevant repository, configuration and authoritative material before declaring readiness"
    And the folder ".kogen/intents/is-even" does not exist
    And the fake ChatGPT server received 3 requests

  @SHP-12
  Scenario: An engineering question does not reach the caller
    Given the fake ChatGPT server plays script "shape-engineering-question"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 1
    And stdout contains "questions: decide technical questions inside shaping; only kind product or handoff may reach the caller"
    And stdout does not contain "Questions for"
    And the folder ".kogen/intents/is-even" does not exist

  @SHP-12
  Scenario: An authentication handoff still reaches the caller
    Given the fake ChatGPT server plays script "shape-auth-handoff"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And stdout contains "Questions for is-even:"
    And stdout contains "This question is an authentication or security handoff, not a design choice."
    And stdout contains "Sign in to the provider before shaping can check this account-scoped capability."
    And the folder ".kogen/intents/is-even" does not exist

  @SHP-13
  Scenario: The shaping request requires documentation lookup
    Given the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    And request 1 contains "When a request materially depends on external, protocol, provider or library facts, Shape finds and retrieves current authoritative documentation itself."
    And request 1 contains "Shape documentation lookup discovers sources and retrieves current authoritative documentation."
    And request 1 contains "A trivial local edit needs no documentation lookup and no network access."
