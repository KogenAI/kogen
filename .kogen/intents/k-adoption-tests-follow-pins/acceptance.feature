Feature: Adoption tests follow pins rather than fullscan constants
  Historical reports: eu2 main 5cf70c29, 01:09Z tuple, windows
  20261104T002038Z and 20261104T010844Z ran go test ./... in cli.
  Fullscan pins ended in e26a4d75cdcc, f0884fde435a, f04edcea9896,
  b9990a3d0903, 97892f55ed4f, 9316891471b5 and e5005fa1daf8.
  Line-aligned cuts can be 12303 bytes with marker at 15, including
  '[... 17743 bytes omitted ...]', rather than an exact 4096-byte head.

  Scenario: A release follows a moved component pin
    Then k-adoption-tests-follow-pins: assembly with pin "v0.0.0-20261103231148-748c085cf3c6" must pass

  Scenario: A release different from the manifest fails
    Then k-adoption-tests-follow-pins: assembly with mismatch "v0.0.0-20261103231148-748c085cf3c6" must fail

  Scenario: A replaced component fails even at the pinned version
    Then k-adoption-tests-follow-pins: assembly with replacement "v0.0.0-20261103154529-b9990a3d0903" must fail

  Scenario Outline: Research defaults follow the loop contract
    Then k-adoption-tests-follow-pins: research defaults with loop "<revision>" must pass

    Examples:
      | revision                                 |
      | c6e2360290d4d8f7e124d68c4e656b38fb350d32 |
      | cfa9b06caf24fd3b25543be9a3bd96054f536287 |
