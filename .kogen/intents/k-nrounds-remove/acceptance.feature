Feature: Remove the superseded native per-round cap
  Scenario: Production no longer exposes the removed cap
    When the native cap production references are collected
    Then the removed native cap reference list is "[]"

  Scenario: Existing default and budget behavior stays green
    When the native cap affected package tests run
    Then the native cap affected package tests exit with 0
