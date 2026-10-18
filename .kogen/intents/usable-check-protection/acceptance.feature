Feature: Usable check protection
  Dependency inputs are not immutable check configuration. Real verification
  configuration and explicitly configured whole-file protection remain protected.

  Scenario: Correct the observed init proposal and land dependency edits
    When I qualify check protection with the installed release in mode "dependencies"
    Then the protection qualification receipt contains:
      | initCode             | 0                                                                                          |
      | initCalls            | 2                                                                                          |
      | correctionNamesPaths | true                                                                                       |
      | protect              | [".formatter.exs"]                                                                         |
      | checks               | ["format","compile","test","go-format","go-test","go-vet","go-build"]                        |
      | shapeCode            | 0                                                                                          |
      | approvalCode         | 0                                                                                          |
      | buildCode            | 0                                                                                          |
      | landed               | true                                                                                       |
      | manifestsChanged     | true                                                                                       |
      | formatterUnchanged   | true                                                                                       |
      | configUnchanged      | true                                                                                       |
      | verified             | ["acceptance 1/1","format passed","compile passed","test passed","go-format passed","go-test passed","go-vet passed","go-build passed"] |
      | reviewApproved       | true                                                                                       |

  Scenario: Editable manifests do not let Build change formatter configuration
    When I qualify check protection with the installed release in mode "formatter"
    Then the protection qualification receipt contains:
      | initCode        | 0                   |
      | initCalls       | 2                   |
      | protect         | [".formatter.exs"]  |
      | shapeCode       | 0                   |
      | approvalCode    | 0                   |
      | buildCode       | 1                   |
      | baselineChanged | true                |
      | headUnchanged   | true                |
      | configUnchanged | true                |

  Scenario Outline: Shaping reports the real contract instead of an imaginary exception
    When I qualify check protection with the installed release in mode "<mode>"
    Then the protection qualification receipt contains:
      | initCode          | 0                                                                                                                        |
      | protect           | <protect>                                                                                                                |
      | shapeCode         | 1                                                                                                                        |
      | contextHasProtect | true                                                                                                                     |
      | blockedTool       | true                                                                                                                     |
      | conflict          | shape/protected_conflict: required edits touch protected files: <path>                                                    |
      | nextAction        | Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override. |
      | noReady           | true                                                                                                                     |
      | noIntent          | true                                                                                                                     |
      | noApproval        | true                                                                                                                     |
      | noBuild           | true                                                                                                                     |
      | headUnchanged     | true                                                                                                                     |
      | configUnchanged   | true                                                                                                                     |
    Examples:
      | mode         | protect                     | path         |
      | manual-mix   | [".formatter.exs","mix.exs"] | mix.exs      |
      | npm-scripts  | ["package.json"]            | package.json |
