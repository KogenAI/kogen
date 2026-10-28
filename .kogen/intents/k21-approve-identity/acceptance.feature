Feature: Approve and Build need a Git identity and name the fixes

  Scenario: Approve without --by and without a Git identity names the exact fixes
    Given a Kogen project with an unapproved Intent and no Git identity anywhere
    When I run kogen intent approve for the Intent with its current hash
    Then the command fails with a nonzero exit
    And the output names "git config user.name"
    And the output names "git config user.email"
    And the output names "--by"
    And the Intent is not approved

  Scenario: Approve with --by approves without a Git identity
    Given a Kogen project with an unapproved Intent and no Git identity anywhere
    When I run kogen intent approve for the Intent with its current hash and --by "Someone"
    Then the command succeeds
    And the Intent is approved by "Someone"

  Scenario: Build without a Git identity stops at start with the fixes and sends no model request
    Given an approved Kogen project with no Git identity anywhere
    When I run kogen intent build for the Intent
    Then the command fails with a nonzero exit
    And the output names "git config user.name"
    And the output names "git config user.email"
    And no model request was sent and no Build run or commit was created
