Feature: Shaping refuses test-runner observers that reject the runner's real output
  The installed release runs against the scripted local provider of go_driver_support.js, in a disposable fixture
  project. Its synthetic bin/rails test prints what minitest's default reporter prints when CI_PROGRESS_BAR=0
  ("1 runs, 7 assertions, 0 failures, 0 errors, 0 skips") and matches a -n/-i value as a literal test name; its test
  file has an existing passing test_widget_passes and an existing failing test_widget_doubles. The shaped step file has
  seven observers in the shapes of research's replay and one observer that accepts "N (runs|tests)" with a plain name.
  No real provider, account, Ruby, Rails or AoR task material is involved.

  Scenario: Seven observer patterns are refused, also unchanged, and the correct observer is published
    When the runner-observer shaper submits the seven-pattern package, resubmits it unchanged, then submits the corrected package and acknowledges it
    Then the runner-observer shape exited with status 0 after 4 shaping requests
    And the published runner-observer package is the corrected package
    And the feedback to runner-observer submissions 1 and 2 was exactly:
      """
      Acceptance rejects the test runner's real output: 7 scenario(s) fail although the test runner reported a passing run, or pass an anchored regular expression as a name filter the runner matches literally; nothing was published. A step that observes a test runner must accept the summary the runner really prints on the unchanged tree (minitest's default reporter prints "N runs", other reporters "N tests") and give a literal name filter (minitest's -n and -i) only the plain test name. Rewrite these steps; resubmitting them unchanged is refused again.
      - An anchored -i filter and a tests-only summary (line 2): the name filter -i ^test_widget_passes$ is a regular expression that the runner matched as a literal test name, so nothing ran: 0 runs, 0 assertions, 0 failures, 0 errors, 0 skips
      - A plain -n filter and a tests-only summary (line 5): the step failed although the test runner reported a passing run: 1 runs, 7 assertions, 0 failures, 0 errors, 0 skips
      - An observer module and a tests-only summary (line 8): the step failed although the test runner reported a passing run: 1 runs, 7 assertions, 0 failures, 0 errors, 0 skips
      - A plain -i filter, the verbose name and a tests-only summary (line 11): the step failed although the test runner reported a passing run: 1 runs, 7 assertions, 0 failures, 0 errors, 0 skips
      - A plain -n filter and a line-anchored tests-only summary (line 14): the step failed although the test runner reported a passing run: 1 runs, 7 assertions, 0 failures, 0 errors, 0 skips
      - An anchored -n filter and a tests-only summary (line 17): the name filter -n ^test_widget_passes$ is a regular expression that the runner matched as a literal test name, so nothing ran: 0 runs, 0 assertions, 0 failures, 0 errors, 0 skips
      - An anchored -i filter and a runs-or-tests summary (line 20): the name filter -i ^test_widget_passes$ is a regular expression that the runner matched as a literal test name, so nothing ran: 0 runs, 0 assertions, 0 failures, 0 errors, 0 skips
      """
    And the feedback to runner-observer submission 3 is readiness observations, not a refusal
    And the runner-observer shaping events record 2 submission_refused events with gate "runner_observer"
    And the first runner-observer shaping request instructions contain:
      """
      Test-runner observers: a step that runs a test runner and judges its output must accept that runner's real output on the unchanged tree, in the environment acceptance runs in. Derive the summary wording and the name-filter semantics from a real run of an existing passing test there, not from memory; an observer control's known-good input is that real output, not hand-written runner text. For example, minitest's default reporter (bin/rails test with CI_PROGRESS_BAR=0) prints "1 runs, 7 assertions, 0 failures, 0 errors, 0 skips" where other reporters print "1 tests, ...", so match "N (runs|tests)"; minitest's -n and -i match a plain name literally, so pass the test name itself, never ^name$. Shape refuses a candidate whose step fails although the test runner it ran reported a passing run, or whose anchored name filter made the runner run nothing.
      """
