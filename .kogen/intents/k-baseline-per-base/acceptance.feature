Feature: Reuse only closed same-base Build baselines
  Scenario: Installed binary reuses the second baseline and invalidates the third
    Then baseline per-base test "TestBaselinePerBaseInstalled" passes proving:
      """
      Package and install the candidate with the existing packaging/install scripts. Use the installed binary for three independent Builds in temporary worktrees sharing the same main commit and machine-local custody, with real approval and deterministic local provider fixtures. Configure the exact check command : . Preserve the starting main for the second Build. Observe exactly one fresh baseline evaluation across the first two Builds, and a baseline_reuse event in the second referencing the first evidence. After a committed one-byte source change, the third Build evaluates fresh with no hit for the old identity. Do not count final verification as baseline execution and do not infer execution counts from exit status alone.
      """

  Scenario: Every declared identity difference invalidates reuse
    Then baseline per-base test "TestBaselinePerBaseIdentity" passes proving:
      """
      Start from a completed eligible baseline. Independently change tracked bytes, untracked bytes, ignored untracked bytes, executable mode, symlink target, ordered check command text, inherited environment and executable identity. Each difference forces fresh evaluation; unchanged identity permits reuse. Use actual temporary Git repositories and worktrees. Unknown or unstable content identity never produces a hit.
      """

  Scenario: Shared machine-local custody does not publish partial evidence
    Then baseline per-base test "TestBaselinePerBaseCustody" passes proving:
      """
      Completed evidence survives process restart and is usable by another worktree of the same repository. Partial, malformed and incompatible entries miss and execute fresh. Concurrent readers never accept incomplete publication. Environment secret values are not persisted. Independent repositories do not inherit each other's evidence.
      """

  Scenario: Failures remain inputs and a hit never waives final checks
    Then baseline per-base test "TestBaselinePerBaseFailures" passes proving:
      """
      An arbitrary-shell check exiting nonzero retains its name, command, actual status and output in configured order on two Builds, with real execution both times and no inferred green. A mixed baseline containing : can reuse only that passing eligible result. Final checks, acceptance/model and independent review still run normally; a failing final check prevents landing even when a baseline hit exists. Preserve 029e83b baseline evidence behavior.
      """

  Scenario: Unknown shell dependencies never become eligible by fingerprinting
    Then baseline per-base test "TestBaselinePerBaseEligibility" passes proving:
      """
      Only the exact command : uses the closed status-0 empty-output evaluator. Whitespace variants, true, sh wrappers, scripts, compound commands and commands reading time, services or undeclared external files execute normally and are never reused. The evaluator itself reads no external input. No new CLI or configuration eligibility switch is introduced.
      """
