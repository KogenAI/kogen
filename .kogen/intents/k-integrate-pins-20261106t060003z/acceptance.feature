Feature: kogen's qualification is green on the adopted component tuple
  The base is the pin commit 16f5c1f8fc7d with every component at its newest main:
  kogen-verification 1b5fb1437a09 -> a83b8096ecdb, kogen-shaping c3f9c5e099e7 -> 88a929ea41ee,
  kogen-build 165a027e8229 -> fdbef3d41add, kogen-executor dcf38d72a0c3 -> c7382270875a,
  kogen-setup 8958731c2ff5 -> 9630cce549f9, kogen-review 66be20d31658 -> 22dc61ec5953.
  The full acceptance suite failed one scenario at the base: spec/features/02-shaping.feature:553
  "An authentication handoff still reaches the caller" ended with exit 1 and
  shape/invalid_output, because kogen-shaping 88a929ea41ee refuses a question without options
  ("question 1 (Sign in to the provider before shaping can check this account-scoped
  capability.): no options").

  Scenario: The authentication handoff reaches the caller with two options, one recommended
    When k-integrate-pins-20261106t060003z: the acceptance suite runs the scenarios tagged "@SHP-12 and not @live" of "spec/features/02-shaping.feature"
    Then k-integrate-pins-20261106t060003z: exactly these scenarios ran and passed every step:
      | scenario                                                                              |
      | The shaping request requires technical discovery                                      |
      | A files submission without repository inspection is rejected                          |
      | An engineering question does not reach the caller                                     |
      | A question the check does not class as UI/UX goes back to the shaper and is not asked |
      | An authentication handoff still reaches the caller                                    |
    And k-integrate-pins-20261106t060003z: the scenario "An authentication handoff still reaches the caller" ends with these steps:
      | step                                                                                                 |
      | the fake ChatGPT server plays script "shape-auth-handoff"                                            |
      | the caller runs "kogen intent shape is-even -" with stdin:                                           |
      | the exit code is 5                                                                                   |
      | stdout contains "Questions for is-even:"                                                             |
      | stdout contains "This question is an authentication or security handoff, not a design choice."      |
      | stdout contains "Sign in to the provider before shaping can check this account-scoped capability."   |
      | stdout contains "a) I have signed in (recommended)"                                                  |
      | stdout contains "b) Pause shaping until I have signed in"                                            |
      | the folder ".kogen/intents/is-even" does not exist                                                   |

  Scenario: The pins stay as adopted, and cli is formatted, builds and vets
    Then k-integrate-pins-20261106t060003z: the cli module resolves the components:
      | module                                | version                                     |
      | github.com/KogenAI/kogen-loop         | v0.0.0 => ./third_party/kogen-loop          |
      | github.com/KogenAI/kogen-coordinator  | v0.0.0-20261105163147-c8126f4156ba          |
      | github.com/KogenAI/kogen-verification | v0.0.0-20261106044425-a83b8096ecdb          |
      | github.com/KogenAI/kogen-shaping      | v0.0.0-20261106032059-88a929ea41ee          |
      | github.com/KogenAI/kogen-build        | v0.0.0-20261106000240-fdbef3d41add          |
      | github.com/KogenAI/kogen-executor     | v0.0.0-20261106043540-c7382270875a          |
      | github.com/KogenAI/kogen-setup        | v0.0.0-20261106022317-9630cce549f9          |
      | github.com/KogenAI/kogen-review       | v0.0.0-20261106032356-22dc61ec5953          |
    And k-integrate-pins-20261106t060003z: the loop pin names module "github.com/KogenAI/kogen-loop" at source head "c2f529be5aa113662aee9b2295b735b130983a9b"
    And k-integrate-pins-20261106t060003z: gofmt lists no file in cli
    And k-integrate-pins-20261106t060003z: "go build ./..." in "cli" succeeds
    And k-integrate-pins-20261106t060003z: "go vet ./..." in "cli" succeeds
