Feature: Internal native no-progress stops
  Scenario Outline: Execute the native no-progress behavioral gates
    When the K-NOPROG Go gate "<test>" runs in "<package>"
    Then the K-NOPROG gate actually passed

    Examples:
      | package | test                         |
      | build   | TestKNoProgDefault           |
      | build   | TestKNoProgBuilderRepeated   |
      | build   | TestKNoProgBuilderChanging   |
      | build   | TestKNoProgFingerprint       |
      | shape   | TestKNoProgNativeRoles       |
