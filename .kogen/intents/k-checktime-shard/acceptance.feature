Feature: Fixed compile-once race shards
  Scenario: Prove the runner on a small real package instead of the ten-pass delivery measurement
    When I run two fixture passes through the fixed race shard runner
    Then each pass compiles once and runs the exact fixture partition with shard wall times below 180 seconds within 120 seconds total
