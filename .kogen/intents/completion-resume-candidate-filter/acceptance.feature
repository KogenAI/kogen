Feature: Resume completion candidate policy coverage
  This feature checks that the Go tests in cli/facts_test.go catch a wrong resume completion policy.
  Each scenario applies one wrong policy to a copy of cli/facts.go.

  Scenario: Wrong resume policy: offers unsupported runs
    When completion-resume-candidate-filter: the cli facts tests run against the resume policy "offers unsupported runs"
    Then completion-resume-candidate-filter: the cli facts tests pass unmodified and fail under that policy

  Scenario: Wrong resume policy: offers landed runs
    When completion-resume-candidate-filter: the cli facts tests run against the resume policy "offers landed runs"
    Then completion-resume-candidate-filter: the cli facts tests pass unmodified and fail under that policy

  Scenario: Wrong resume policy: offers already present runs
    When completion-resume-candidate-filter: the cli facts tests run against the resume policy "offers already present runs"
    Then completion-resume-candidate-filter: the cli facts tests pass unmodified and fail under that policy

  Scenario: Wrong resume policy: drops potentially available runs
    When completion-resume-candidate-filter: the cli facts tests run against the resume policy "drops potentially available runs"
    Then completion-resume-candidate-filter: the cli facts tests pass unmodified and fail under that policy

  Scenario: Wrong resume policy: keeps input order
    When completion-resume-candidate-filter: the cli facts tests run against the resume policy "keeps input order"
    Then completion-resume-candidate-filter: the cli facts tests pass unmodified and fail under that policy
