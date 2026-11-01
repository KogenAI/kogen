Feature: Remove acceptance liveness padding without weakening observations
  Scenario: Real-handler regressions and affected-only measurements pass
    When fixed-wait acceptance runs the regression entry point
    Then fixed-wait acceptance succeeds with "fixed-wait regression passed"
