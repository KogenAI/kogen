Feature: Re-pin kogen-loop to 2ea31bf5 and use its process-group safety in Kogen

  Scenario: The vendored copy is exactly the clean source at 2ea31bf5
    Given KOGEN_LOOP_SOURCE names a clean kogen-loop checkout at 2ea31bf5
    Then the vendored loop has 111 files, none under .kogen or features, byte-equal to that checkout
    And cli/loop-pin.json is exactly:
      """
      {"module":"kogen-loop","protocol":"kogen-loop/v1","library":"loop/v1","digest":"0f2daaefc9f0c6c22851dc29df1f774a7d8c863261200eac16e1489435cecec1","files":111,"source_head":"2ea31bf5438f0bdde537848f678a7331c5fe2a2a","source_state":"clean"}
      """
    And TestLoopPin passes

  Scenario Outline: A probe that would stop a sibling process is refused and the round continues
    Given a sibling process built from a tiny Go program is running under a unique name
    When a probe runs "<command>"
    Then the probe result has status 126 and output exactly "<text>"
    And the sibling is still alive
    And the round continues: the next probe in the same session has status 0 and output "continued\n"

    Examples:
      | command               | text                                                                                                                                                                                                                                                   |
      | pkill -f SIBLING_NAME | refused: this command would stop processes this run did not start (rule: no pkill or killall; kill only pids this run created). Stop what you started with its own pid, for example kill $!, or its process group. |
      | killall SIBLING_NAME  | refused: this command would stop processes this run did not start (rule: no pkill or killall; kill only pids this run created). Stop what you started with its own pid, for example kill $!, or its process group. |
      | kill SIBLING_PID      | refused: this command would stop processes this run did not start (rule: kill only pids this run created). Stop what you started with its own pid, for example kill $!, or its process group.                                                       |

  Scenario: A probe that starts a background sleep leaves no group member behind
    When a probe runs "sleep 60 >/dev/null 2>&1 & echo $! > PIDFILE; echo done; exit 4"
    Then the probe result has status 4 and output exactly "done\n"
    And the recorded background process is gone

  Scenario: A configured check that starts a background sleep leaves no group member behind
    When Kogen runs the configured check "sleep 60 >/dev/null 2>&1 & echo $! > PIDFILE; exit 3" through cli/build
    Then the check is reported failing with status 3
    And the recorded background process is gone

  Scenario: A probe with a short deadline still reports a timeout
    When a probe runs "sleep 30" under a 200 ms deadline
    Then the probe result reports a timeout

  Scenario: Kogen sources set the process-group options as requested and add no timeout
    Then every command Kogen runs with sys.Options sweeps its process group and only probes refuse foreign kills

  Scenario: The specification and executor contract state the enforcement and its limits
    Then the specification and the executor contract state what Kogen enforces and cannot enforce

  Scenario: A new evidence note records the re-pin and older notes stay intact
    Then a re-pin evidence note names 2ea31bf5, 111 files and the new digest while the older notes keep their history
