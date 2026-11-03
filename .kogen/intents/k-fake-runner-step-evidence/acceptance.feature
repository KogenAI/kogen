Feature: Kogen's fake acceptance runner reports complete step evidence

  Kogen's acceptance suite replaces the acceptance command with the fake runner
  test/acceptance/fixtures/runners/run.js. Each mode is run on the is-even fixture feature
  as the suite runs it, and its exit status and report are accounted by the real
  verify.Account of kogen-verification at the version cli/go.mod pins and at 11a5244,
  which accepts a report only when every source step maps through its pickle step to a
  test-case step with exactly one final result.

  Scenario Outline: Fixture runner mode "<mode>" keeps its intended outcome on the current pin and on 11a5244
    Given Kogen's fake acceptance runner runs in mode "<mode>" on the is-even fixture feature
    Then kogen-verification at the current pin and at 11a5244 both account exit <exit>, scenarios "<statuses>" and problems "<problems>"

    Examples:
      | mode               | exit | statuses                                     | problems                                                     |
      | exits-1-all-passed | 1    | passed,passed,passed                         | exit 1 with all scenarios passed                             |
      | reports-undefined  | 0    | undefined,passed,passed                      | undefined: Even numbers (line 3)                             |
      | reports-skipped    | 0    | skipped,passed,passed                        | skipped: Even numbers (line 3)                               |
      | omits-one-scenario | 0    | passed,passed,missing                        | missing: Non-integers (line 13)                              |
      | reports-one-twice  | 0    | duplicate,passed,passed                      | duplicate: Even numbers (line 3)                             |
      | writes-no-report   | 0    | report_missing,report_missing,report_missing | report_missing: the acceptance command exited 0; its output: |
