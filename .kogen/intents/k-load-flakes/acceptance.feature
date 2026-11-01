Feature: The preflight start check waits on the preflight's own start
  TestPreflightStopsOwnedChildren (cli/executor/claudecode/preflight_process_test.go) waits until its
  fake claude has observably started or its preflight has ended, not for a fixed five seconds. The test
  itself delays or prevents that start through preflightFakeStart; nothing loads the host.

  Scenario: A preflight whose start is slower than five seconds is waited for
    When TestPreflightStopsOwnedChildren runs with the fake claude first running "sleep 6"
    Then TestPreflightStopsOwnedChildren passes with early_exit and cancelled each taking more than 5.00 seconds

  Scenario: A preflight that really does not start still fails the test
    When TestPreflightStopsOwnedChildren runs with the fake claude first running "exit 0"
    Then TestPreflightStopsOwnedChildren fails with "preflight did not start" in early_exit and in cancelled

  Scenario: A preflight that starts at once passes as before
    When TestPreflightStopsOwnedChildren runs with its fake claude unchanged
    Then TestPreflightStopsOwnedChildren passes with early_exit and cancelled
