Feature: kogen's qualification is green on the new component tuple
  The base is the pin commit d5359e93a933 with every component at its newest main:
  kogen-loop 3505e6023bdb -> 84ee1ed6652f, kogen-build 88b77ba3dbf3 -> 45d5823fa40c,
  kogen-setup c0afc56136fe -> 43be668ea101.
  At the base, go test ./... in cli failed kogen/consumes/kogen-build:
  TestRecoverRefusalsAreSysErrorsWithTheirExit/unknown_id and /absent_checkpoint, and
  TestResumeRefusalsAreSysErrorsWithTheirExit/unknown_id, because kogen-build 45d5823fa40c
  refuses a malformed id with '"nothex" is not a Build id; ...' and an unrecorded id with
  'Build 00000000: no Build with this id in this checkout; ...'.

  Scenario: The pins stay as adopted and the kogen-build consumer suite passes
    Then k-integrate-pins-20261107t000001z: the cli module resolves the components:
      | module                                | version                                    |
      | github.com/KogenAI/kogen-loop         | v0.0.0 => ./third_party/kogen-loop         |
      | github.com/KogenAI/kogen-coordinator  | v0.0.0-20261106121202-e91a9e0ac65b         |
      | github.com/KogenAI/kogen-verification | v0.0.0-20261106121212-e1ff81b79447         |
      | github.com/KogenAI/kogen-shaping      | v0.0.0-20261106124640-0484edf817f6         |
      | github.com/KogenAI/kogen-build        | v0.0.0-20261106191737-45d5823fa40c         |
      | github.com/KogenAI/kogen-executor     | v0.0.0-20261106121702-55b372c4dd31         |
      | github.com/KogenAI/kogen-setup        | v0.0.0-20261106184805-43be668ea101         |
      | github.com/KogenAI/kogen-review       | v0.0.0-20261106124750-cdcbbe3e357a         |
    And k-integrate-pins-20261107t000001z: the loop pin names module "github.com/KogenAI/kogen-loop" at source head "84ee1ed6652fd8af15a33e5e5c268a89ea2564c9"
    And k-integrate-pins-20261107t000001z: gofmt lists no file in cli
    And k-integrate-pins-20261107t000001z: "go build ./..." in "cli" succeeds
    And k-integrate-pins-20261107t000001z: "go vet ./..." in "cli" succeeds
    When k-integrate-pins-20261107t000001z: go test runs the whole package "./consumes/kogen-build" in cli
    Then k-integrate-pins-20261107t000001z: the package passed with each of these tests run once and passed:
      | test                                                           |
      | TestRecoverRefusalsAreSysErrorsWithTheirExit                   |
      | TestRecoverRefusalsAreSysErrorsWithTheirExit/unknown_id        |
      | TestRecoverRefusalsAreSysErrorsWithTheirExit/absent_checkpoint |
      | TestResumeRefusalsAreSysErrorsWithTheirExit                    |
      | TestResumeRefusalsAreSysErrorsWithTheirExit/unknown_id         |
      | TestResumeRefusalsAreSysErrorsWithTheirExit/HEAD_moved         |
      | TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation   |

  Scenario: The consumer tests and their README state kogen-build's new refusal texts
    Then k-integrate-pins-20261107t000001z: the file "cli/consumes/kogen-build/recover_test.go" contains each of these texts:
      | text                                                                                                          |
      | is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; kogen intent list lists Build attempts |
      | no Build with this id in this checkout; kogen intent list lists Build attempts                                |
      | unknown checkpoint: absent checkpoint                                                                         |
      | checkpoint.json                                                                                               |
    And k-integrate-pins-20261107t000001z: the file "cli/consumes/kogen-build/recover_test.go" contains none of these texts:
      | text                                                  |
      | "candidate/recovery_unsupported: unknown checkpoint"  |
      | "candidate/recovery_unsupported: absent checkpoint"   |
    And k-integrate-pins-20261107t000001z: the file "cli/consumes/kogen-build/resume_test.go" contains each of these texts:
      | text                                                                                                          |
      | is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; kogen intent list lists Build attempts |
      | no Build with this id in this checkout; kogen intent list lists Build attempts                                |
      | no newly created Build run                                                                                    |
    And k-integrate-pins-20261107t000001z: the file "cli/consumes/kogen-build/README.md" contains each of these texts:
      | text                                   |
      | is not a Build id                      |
      | no Build with this id in this checkout |
      | unknown checkpoint: absent checkpoint  |
      | kogen intent list                      |
