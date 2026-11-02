Feature: Background servers started by an acceptance run do not outlive it
  K-ACCEPT-SERVER-LEAK (Studio kogen issue f8d0ce5a-cfa0-479a-ac58-46f052087d63, EU host, 31 Oct 2026): after
  grading a cell at about 14:56Z, `python3 -m http.server 8765`, a `python3 -c from calc import ...` and the node
  Cucumber runner of an acceptance run kept running with parent pid 1 in their own process groups (1918367 and
  1919636) for 3.5 hours until stopped by hand, and the next research cell waited behind them. When an acceptance
  run ends, passed, failed or timed out, every process it started is stopped, including servers a step put in the
  background in another process group or session; only processes the run started are touched. The fixture
  servers bind 127.0.0.1 on a free port instead of 8765, so concurrent runs cannot collide; every server the
  fixtures cause is killed by the harness afterwards, so a red run leaves nothing behind.

  Scenario Outline: Approval through the bundled Cucumber leaves no background server of its <scenario> fixture scenario
    When the packaged Kogen approves a fixture whose passing and failing scenarios each put python3 -m http.server in the background
    Then the approval ran both fixture scenarios through the bundled Cucumber
    And the server started outside the approval run is still running
    And no background server from the approval run of the "<scenario>" fixture scenario is still running

    Examples:
      | scenario |
      | passing  |
      | failing  |

  Scenario Outline: An acceptance run that <outcome> leaves no background server it started
    When acceptance commands that put python3 -m http.server in the background are run through RunAcceptance
    Then the server started outside the acceptance runs is still running
    And no background server from the "<mode>" acceptance run is still running

    Examples:
      | outcome   | mode      |
      | passed    | passed    |
      | failed    | failed    |
      | timed out | timed_out |
