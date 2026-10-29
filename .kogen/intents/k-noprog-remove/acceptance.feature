Feature: Remove the unused native fingerprint policy
  Scenario: The first-party native option and outcome are gone
    When the removed native fingerprint identifiers are collected
    Then the native fingerprint reference paths are "[]"

  Scenario: Default Build and the separate progress guards remain intact
    When the fingerprint removal affected packages run
    Then the fingerprint removal package command exits with 0
