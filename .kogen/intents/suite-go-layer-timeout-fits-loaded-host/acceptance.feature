Feature: The go layer of the suite fits a loaded host
  This feature checks that test/suite.sh runs the go layer with an explicit per-package limit of 40 minutes
  and keeps the layer's working directory and failure handling.

  Scenario: The go layer passes an explicit limit of 40 minutes
    Given suite-go-layer-timeout-fits-loaded-host: a scratch project with the maintained suite and fake spec, live-helper and acceptance layers
    And suite-go-layer-timeout-fits-loaded-host: a fake go executable that records its arguments and working directory and exits 0
    When suite-go-layer-timeout-fits-loaded-host: the suite is run
    Then suite-go-layer-timeout-fits-loaded-host: go was invoked exactly once with the arguments "test -race -count=1 -timeout=40m ./..."
    And suite-go-layer-timeout-fits-loaded-host: the suite exits with status 0

  Scenario: The go layer runs in the cli directory
    Given suite-go-layer-timeout-fits-loaded-host: a scratch project with the maintained suite and fake spec, live-helper and acceptance layers
    And suite-go-layer-timeout-fits-loaded-host: a fake go executable that records its arguments and working directory and exits 0
    When suite-go-layer-timeout-fits-loaded-host: the suite is run
    Then suite-go-layer-timeout-fits-loaded-host: go ran in the cli directory of the scratch project

  Scenario: A failing go exit status fails the suite
    Given suite-go-layer-timeout-fits-loaded-host: a scratch project with the maintained suite and fake spec, live-helper and acceptance layers
    And suite-go-layer-timeout-fits-loaded-host: a fake go executable that records its arguments and working directory and exits 1
    When suite-go-layer-timeout-fits-loaded-host: the suite is run
    Then suite-go-layer-timeout-fits-loaded-host: the suite prints a line that starts with "suite: go FAILED"
    And suite-go-layer-timeout-fits-loaded-host: the suite prints no line that starts with "suite: all passed"
    And suite-go-layer-timeout-fits-loaded-host: the suite exits with status 1
