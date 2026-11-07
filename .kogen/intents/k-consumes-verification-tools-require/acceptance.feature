Feature: Keep executable tool fixtures compatible with Require
  The historical consumer report observed exit 3 instead of 5 or 1 and
  [snapshot materialize setup-1] instead of reaching acceptance. This contract
  preserves the current tests' outcomes rather than asserting that history occurs now.

  Scenario: Existing test outcomes survive both tool contracts
    Then k-consumes-verification-tools-require: the existing init node fixture uses executable mode 0755
    And k-consumes-verification-tools-require: the approval and tool consumer tests retain their outcomes under both Require contracts:
      | package                        | filter                    | required tests                                                                                                                                                               |
      | .                              | ^TestApprove              | TestApproveDeadlineSplitCLI,TestApproveDeadlineHungCLI,TestApproveFailureOutputCLI,TestApproveFailureEvidenceCLI,TestApproveFailureBoundsCLI                                    |
      | ./consumes/kogen-shaping        | ^TestApprove              | TestApproveWithoutAHashShowsTheCardWithExit5,TestApproveRunsTheAcceptanceCommandWithTheTools,TestApproveWithTheHashPublishesTheApproval,TestApproveRefusalsAreSysErrorsWithTheirExit |
      | ./consumes/kogen-verification   | ^TestTools                | TestToolsFields,TestToolsFromInstallNamesTheNodeOfTheInstall,TestToolsFromInstallWithoutNodePathFile,TestToolsFromInstallLocatesQuintAndCucumberUnderLib                           |
      | .                              | ^TestInitReadinessNext$    | TestInitReadinessNext                                                                                                                                                         |
