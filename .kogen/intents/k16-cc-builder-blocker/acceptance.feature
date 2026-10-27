Feature: A Claude Code builder can report a protected-contract blocker

  Scenario: A blocker naming a protected step file stops the Build and can be recovered
    When the k16 fake Claude Code build round reports the blocker case "protected-step-file"
    Then the k16 Build stopped with the candidate build_blocked result as BUILDER-REPORTED naming that protected step file, with the candidate, index and approval preserved
    And the k16 intent recover of that Build succeeded and cleaned only the implementation

  Scenario: A blocker naming a non-protected path is refused as native refuses it
    When the k16 fake Claude Code build round reports the blocker case "unprotected-path"
    Then the k16 Build refused the report as native does, recorded no blocker and fed the invalid-blocker message back

  Scenario: A blocker reported after HEAD moved is refused
    When the k16 fake Claude Code build round reports the blocker case "moved-head"
    Then the k16 Build stopped with the candidate head_moved result and no recorded blocker

  Scenario: An executor whose descriptor declares no Blocker still gets a protocol failure
    When the k16 fake Claude Code build round reports the blocker case "undeclared-blocker"
    Then the k16 Build stopped with the executor protocol failure and no recorded blocker

  Scenario: The descriptor and the build constraints announce the blocker report
    When the k16 Claude Code executor is described and its constraints read
    Then the k16 Claude Code build role declares Blocker while its shape and review roles do not
    And the k16 build constraints carry the native blocker wording and still refuse protected edits
