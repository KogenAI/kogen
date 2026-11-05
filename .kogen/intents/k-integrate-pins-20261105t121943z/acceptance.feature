Feature: kogen's qualification is green on the adopted component tuple
  The base is the pin commit d5fcf5cedf09 with every component at its newest main:
  kogen-loop cfa9b06caf24 -> b2b2c6c5430e, kogen-coordinator 03d7341feab7 -> 1ac897fc50e9,
  kogen-verification 3cb7305a5690 -> ec39831718de, kogen-shaping f04edcea9896 -> cfaa44cac971,
  kogen-build b9990a3d0903 -> 956b151a6564, kogen-executor 9021591798ac -> 22b32ebeaa6d,
  kogen-setup 9316891471b5 -> 8958731c2ff5, kogen-review e5005fa1daf8 -> 2fd0a09cbdf5.
  Adoption receipt 20261105T120005Z (final go step rc=1) failed TestLoopPin,
  TestKReviewVerdictStrandPinnedResume, TestShapeWorkers,
  TestParseConfigRefusalsAreSysErrorsWithLines (and its workers_without_roles subtest,
  whose behavior kogen-coordinator removed), TestReadableConfigKeepsWhatItCanRead and
  TestInitUsesTheClientAndTheToolsOfTheInput.

  Scenario: The adoption's consumer reds pass with the pins unchanged
    Then k-integrate-pins-20261105t121943z: the cli module resolves the components:
      | module                                  | version                                     |
      | github.com/KogenAI/kogen-loop           | v0.0.0 => ./third_party/kogen-loop          |
      | github.com/KogenAI/kogen-coordinator    | v0.0.0-20261105095503-1ac897fc50e9          |
      | github.com/KogenAI/kogen-verification   | v0.0.0-20261105102700-ec39831718de          |
      | github.com/KogenAI/kogen-shaping        | v0.0.0-20261105115315-cfaa44cac971          |
      | github.com/KogenAI/kogen-build          | v0.0.0-20261105094636-956b151a6564          |
      | github.com/KogenAI/kogen-executor       | v0.0.0-20261105105831-22b32ebeaa6d          |
      | github.com/KogenAI/kogen-setup          | v0.0.0-20261105091508-8958731c2ff5          |
      | github.com/KogenAI/kogen-review         | v0.0.0-20261105081449-2fd0a09cbdf5          |
    And k-integrate-pins-20261105t121943z: the loop pin names module "github.com/KogenAI/kogen-loop" at source head "b2b2c6c5430efb564f6e200189adf09d23c774ea"
    And k-integrate-pins-20261105t121943z: gofmt lists no file in cli
    And k-integrate-pins-20261105t121943z: "go build ./..." in "cli" succeeds
    And k-integrate-pins-20261105t121943z: "go vet ./..." in "cli" succeeds
    And k-integrate-pins-20261105t121943z: these Go tests pass in one run:
      | test                                         | package                      |
      | TestLoopPin                                  | .                            |
      | TestKReviewVerdictStrandPinnedResume         | ./buildprogram               |
      | TestShapeWorkers                             | ./consumes/kogen-coordinator |
      | TestParseConfigRefusalsAreSysErrorsWithLines | ./consumes/kogen-coordinator |
      | TestReadableConfigKeepsWhatItCanRead         | ./consumes/kogen-coordinator |
      | TestInitUsesTheClientAndTheToolsOfTheInput   | ./consumes/kogen-setup       |
