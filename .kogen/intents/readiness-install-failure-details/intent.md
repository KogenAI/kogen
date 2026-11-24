# Identify failed bundled tool paths and statuses

Slug: readiness-install-failure-details
Model: not applicable — this changes diagnostic content for independent version-command results, not state transitions
Acceptance:
- .kogen/intents/readiness-install-failure-details/acceptance.feature
- features/steps/readiness-install-failure-details__steps.js
- features/steps/readiness-install-failure-details__driver/main.go
- features/steps/readiness-install-failure-details__driver/observe.cjs

Fix ev-70d545e5: replace the generic bundled-tool failure diagnostic with one identifying the failing tool, its configured path and its exit status. Continue checking the bundled tools and include their failures together in the install report. Production changes are confined to cli/readiness/readiness.go and cli/readiness/readiness_test.go. Update the install regression coverage, retaining useful existing tests. Do not change installation, version requirements, version commands, or expose arbitrary subprocess output.

## Decisions
- Multiple failures appear in one install report, and successful commands are not listed as failures. (decision: D1, round 1) (evidence: cli/readiness/readiness.go) (source: request)
- Identify each failed command by its own tool name and configured Tools field: Node, Cucumber or Quint, even when a command uses Node to launch the other tool. Cucumber's configured path is the module directory, not a replacement path inferred from its script suffix. Preserve the existing aggregate report, reinstall fix and successful report. (decision: D2, round 1) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- Exercise readiness.Run and readiness.Text through a compiled Go driver with local version-command fixtures; no production test seam or additional dependency is needed. Assert tool/path/status association rather than imposing new diagnostic wording. (decision: D3, round 1) (evidence: cli/readiness/readiness.go; features/steps/readiness-config-read-errors__driver/main.go; features/steps/readiness-config-read-errors__steps.js) (source: request)

## Source comparison
- Addressed: request evidence ev-70d545e5 and acceptance 1 require the missing configured Node path and nonzero status, replacing the generic message. The missing-Node scenario in acceptance.feature checks each affected command; controls.json includes generic-message, omitted-status and incorrect-status counterexamples.
- Addressed: request acceptance 2 requires separate Cucumber and Quint diagnoses with their own configured paths and statuses, not diagnoses all attributed to Node. The two single-failure scenarios assert these outcomes with successful peer commands excluded; controls.json exercises wrong attribution and omitted paths.
- Addressed: request acceptance 3 requires aggregation and exclusion of successful commands. The multiple-failure and successful-report scenarios check both outcomes; controls.json includes early-stop and false-failure counterexamples.
- Addressed: requested implementation scope is cli/readiness/readiness.go and cli/readiness/readiness_test.go. The helper artifacts are protected acceptance only. Installation, version requirements and arbitrary subprocess-output reporting remain out of scope; the scenarios reject fixture output leaking into the report.
- Omitted: none of the requested behavior. No conflicting or superseded product requirement was found; only the generic failure diagnostic is superseded.

## Tests
- Missing Node identifies its configured path and nonzero status: extend TestInstallCheck and exercise the missing-Node acceptance scenario through readiness.Run and Text (regression)
- Failed Cucumber and Quint commands identify their own configured paths and statuses: extend install regression coverage and exercise separate local failing-command scenarios (integration)
- Aggregate failures and exclude successful commands: exercise mixed outcomes and all-success reporting with the compiled readiness driver (integration)
- Existing install behavior remains intact outside failure details: retain VERSION-file coverage and the successful install report and reinstall fix in cli/readiness/readiness_test.go (existing)

## Feasibility
- Local scratch preparation compiled the submitted Go driver and captured real reports from the bounded correct overlay for the observer fixtures; production files were untouched. The final observer accepted all five good reports and rejected all eight independently corrupted reports, including deeper aggregate and output-exclusion assertions.
- evidence: {"id":"install-observer","kind":"observer","inputs":[".kogen/intents/readiness-install-failure-details/observer-fixtures.json","features/steps/readiness-install-failure-details__driver/main.go","features/steps/readiness-install-failure-details__steps.js"],"observers":["features/steps/readiness-install-failure-details__driver/observe.cjs"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/readiness-install-failure-details__driver/observe.cjs .kogen/intents/readiness-install-failure-details/observer-fixtures.json good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/readiness-install-failure-details__driver/observe.cjs .kogen/intents/readiness-install-failure-details/observer-fixtures.json bad","exit":1,"output":"rejected\n"}]}
