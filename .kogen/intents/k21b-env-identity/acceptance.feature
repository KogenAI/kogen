Feature: The Build identity check accepts an identity from Git's environment

  Scenario: Build passes the identity check with an identity only in the environment
    Given an approved Kogen project with no Git identity anywhere
    And the process environment sets the Git author and committer name and email
    When I run kogen intent build for the Intent
    Then the output does not name "git_identity_missing"
    And the Build got past its start checks

  Scenario: Doctor reports git ok with an identity only in the environment
    Given an approved Kogen project with no Git identity anywhere
    And the process environment sets the Git author and committer name and email
    When I run kogen doctor with quick checks in the project
    Then the doctor git line is ok

  Scenario: Build refuses when only the author identity is in the environment
    Given an approved Kogen project with no Git identity anywhere
    And the process environment sets only the Git author name and email
    When I run kogen intent build for the Intent
    Then the command fails with a nonzero exit
    And the output names "git_identity_missing"
    And no model request was sent and no Build run or commit was created

  Scenario: Doctor fails when only the author identity is in the environment
    Given an approved Kogen project with no Git identity anywhere
    And the process environment sets only the Git author name and email
    When I run kogen doctor with quick checks in the project
    Then the doctor git line is fail

  Scenario: An auto-guessed identity is refused by Build and doctor
    Given an approved Kogen project with no Git identity anywhere
    When I run kogen intent build for the Intent
    Then the command fails with a nonzero exit
    And the output names "git_identity_missing"
    And no model request was sent and no Build run or commit was created
    When I run kogen doctor with quick checks in the project
    Then the doctor git line is fail
