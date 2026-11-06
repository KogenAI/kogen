Feature: kogen intent inspect of an unknown run says which runs exist

  Background:
    Given k-cli-inspect-unknown-run-names-next-command: a Kogen project checkout and the CLI built from the current sources

  Scenario Outline: A malformed run id is reported as not a run id and names the command that lists runs
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "<id>" with standard output piped
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 1
    And k-cli-inspect-unknown-run-names-next-command: standard error is empty
    And k-cli-inspect-unknown-run-names-next-command: standard output is exactly the one JSON line for this checkout with the error:
      """
      {"class":"intent","reason":"run_not_found","detail":"not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d","paths":[],"next":"kogen intent list"}
      """

    Examples:
      | id        |
      | run-1     |
      | 0a1b2c3   |
      | 0a1b2c3d4 |
      | 0A1B2C3D  |

  Scenario: A well-formed run id with no record says no run has this id and names the command that lists runs
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "0a1b2c3d" with --json and standard output piped
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 1
    And k-cli-inspect-unknown-run-names-next-command: standard error is empty
    And k-cli-inspect-unknown-run-names-next-command: standard output is exactly the one JSON line for this checkout with the error:
      """
      {"class":"intent","reason":"run_not_found","detail":"no run with this id in this checkout","paths":[],"next":"kogen intent list"}
      """

  Scenario: On a terminal a malformed id gets a sentence after the same JSON line
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "run-1" on a terminal
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 1
    And k-cli-inspect-unknown-run-names-next-command: the terminal output is the JSON line for this checkout with the error, then the line "not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d. Next: kogen intent list":
      """
      {"class":"intent","reason":"run_not_found","detail":"not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d","paths":[],"next":"kogen intent list"}
      """

  Scenario: On a terminal a well-formed absent id gets a sentence after the same JSON line
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "0a1b2c3d" on a terminal
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 1
    And k-cli-inspect-unknown-run-names-next-command: the terminal output is the JSON line for this checkout with the error, then the line "no run with this id in this checkout. Next: kogen intent list":
      """
      {"class":"intent","reason":"run_not_found","detail":"no run with this id in this checkout","paths":[],"next":"kogen intent list"}
      """

  Scenario: Standard output that is not a terminal gets no added sentence
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "run-1" with standard output discarded
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 1
    And k-cli-inspect-unknown-run-names-next-command: standard error is empty

  Scenario: Piped standard output stays the bare JSON line even when standard error is a terminal
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "0a1b2c3d" piped to cat on a terminal
    Then k-cli-inspect-unknown-run-names-next-command: the terminal output is the JSON line for this checkout with the error:
      """
      {"class":"intent","reason":"run_not_found","detail":"no run with this id in this checkout","paths":[],"next":"kogen intent list"}
      """

  Scenario: A recorded run prints as before
    Given k-cli-inspect-unknown-run-names-next-command: a recorded run "0a1b2c3d" with the record:
      """
      {"run_id":"0a1b2c3d","checkout_id":"<checkout id>","slug":"fixture","state":"landed","phase":"committing","resume_status":"unsupported","verification":[],"reviews":[],"blockers":[],"locations":{"candidate":"/c","run_dir":"/r","log":"/r/log","checkpoint":"/r/checkpoint.json"},"resumed_from":null,"root_run":"0a1b2c3d","verification_pass":null,"reason":null,"commit":"0123456789012345678901234567890123456789","evidence_truncated":false}
      """
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "0a1b2c3d" with --json and standard output piped
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 0
    And k-cli-inspect-unknown-run-names-next-command: standard error is empty
    And k-cli-inspect-unknown-run-names-next-command: the JSON error is null and the JSON data is:
      """
      {"run_id":"0a1b2c3d","checkout_id":"<checkout id>","slug":"fixture","state":"landed","phase":"committing","resume_status":"unsupported","verification":[],"reviews":[],"blockers":[],"locations":{"candidate":"/c","run_dir":"/r","log":"/r/log","checkpoint":"/r/checkpoint.json"},"resumed_from":null,"root_run":"0a1b2c3d","verification_pass":null,"reason":null,"commit":"0123456789012345678901234567890123456789","evidence_truncated":false,"next_command":null,"observations":{"activity_checked_now":true,"resume_authorized":false}}
      """
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "0a1b2c3d" with standard output piped
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 0
    And k-cli-inspect-unknown-run-names-next-command: standard output is exactly:
      """
      Build 0a1b2c3d · fixture · landed · committing
        commit: 0123456789012345678901234567890123456789
        resume: unsupported (not authorization)
        candidate: /c; evidence: /r
      """
    When k-cli-inspect-unknown-run-names-next-command: I run kogen intent inspect "0a1b2c3d" on a terminal
    Then k-cli-inspect-unknown-run-names-next-command: the exit code is 0
    And k-cli-inspect-unknown-run-names-next-command: the terminal output is exactly:
      """
      Build 0a1b2c3d · fixture · landed · committing
        commit: 0123456789012345678901234567890123456789
        resume: unsupported (not authorization)
        candidate: /c; evidence: /r
      """
