Feature: Specification vocabulary integrity
  Scenario: The original full specification wrapper passes
    When I run the full specification wrapper
    Then the specification wrapper exits with 0
    And the specification wrapper SHA-256 is "fad3050db757525b11459a325b9ef2f8c47368e810e60aea44cb8c63797d18f3"
    And the specification wrapper output includes:
      """
      requirements 102, scenarios 146,
      spec check: ok
      == quint typecheck + test shaping.qnt
      == quint typecheck + test build.qnt
      == quint typecheck + test run_control.qnt
      == quint run shaping.qnt --invariant Safety (seed 7, 2000 samples, 20 steps)
      == quint run build.qnt --invariant Safety (seed 11, 3000 samples, 60 steps)
      == quint run run_control.qnt --invariant Safety (seed 3, 3000 samples, 30 steps)
      == non-vacuity ok: run_control.qnt reaches not(refusal != "build_running")
      spec checks: all ok
      """
