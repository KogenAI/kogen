# Report complete step evidence from the fake runner

Slug: k-fake-runner-step-evidence
Model: not applicable — a test-support report writer that turns one feature file into one fixed report per mode; no state machine
Acceptance:
- .kogen/intents/k-fake-runner-step-evidence/acceptance.feature
- features/steps/k_fake_runner_step_evidence_steps.js
- features/steps/k_fake_runner_step_evidence_check.cjs
- features/steps/k_fake_runner_step_evidence_driver.go
- features/steps/k_fake_runner_step_evidence_control.cjs

Kogen's own acceptance suite replaces the acceptance command with the fake runner `test/acceptance/fixtures/runners/run.js` (wired by `installAcceptanceRunner` in `test/acceptance/support/handlers.js`; used by `spec/features/05-verifying.feature` line 37, the outline "A report that is not a clean pass is a failing check", and by the `hangs` mode in `spec/features/09-cli-and-process.feature`). This change is test support only (change_type test-fix): the fake runner's Cucumber Messages reports gain complete step evidence so that kogen-verification 11a5244 ("Require proof for verification success", `github.com/KogenAI/kogen-verification v0.0.0-20261103052035-11a5244e95ee`) accounts each mode exactly as the current pin (`v0.0.0-20261102193616-587f67dae7e8`) does.

What the code does now: for every reported scenario the fake runner writes a `gherkinDocument` whose scenarios have `steps: []`, a `pickle` with `steps: []`, a `testCase` with one `testSteps` entry `{id}` that has neither `pickleStepId` nor `hookId`, and one `testStepFinished` for that step. The current pin accepts this. 11a5244's `reportCoverage`/`coverageMatches` (verify/report.go) require every pickle step to point (first `astNodeIds` entry) to a distinct gherkinDocument step, every test step to carry a distinct `pickleStepId` of that pickle or a `hookId`, every pickle step to be covered, exactly one `testStepFinished` per test step, and the resulting (line, keyword, text) list to equal the feature's own steps as Kogen parses them (keyword with its trailing space, for example `Given `). Otherwise the scenario is `report_invalid`. Observed with the real 11a5244 `verify.Account` on the is-even fixture: every mode's reported scenarios become `report_invalid`, so `exits-1-all-passed` no longer yields `exit 1 with all scenarios passed` (the 3 Nov 06:00Z red on 05-verifying.feature:54), and `reports-undefined`, `reports-skipped`, `omits-one-scenario` and `reports-one-twice` also turn their otherwise-passing scenarios into `report_invalid`.

What the product should do: for every scenario it reports, the fake runner emits
- in the `gherkinDocument`, the scenario's steps, each with a unique `id`, `keyword` exactly as written including its trailing space (`Given `, `When `, `Then `, `And `, `But `, `* `), `text` and `location.line` (the step's 1-based line in the feature);
- in the `pickle`, one step per source step in order, each with a unique `id`, the step `text` and `astNodeIds` whose first entry is that source step's id;
- in the `testCase`, one test step per pickle step, each with a unique `id` and `pickleStepId` set to its pickle step;
- exactly one `testStepFinished` per declared test step of each started test case.

Each mode keeps its purpose and its deliberately bad shape:
- no mode / any other value: every step `PASSED`, exit 0;
- `exits-1-all-passed`: every step `PASSED`, exit 1;
- `reports-undefined`: in the first scenario, the first step `UNDEFINED` with message `step definition is missing` and its later steps `SKIPPED`; others `PASSED`;
- `reports-skipped`: every step of the first scenario `SKIPPED`; others `PASSED`;
- `omits-one-scenario`: the last scenario is not reported (no pickle, test case or results), others complete and `PASSED`;
- `reports-one-twice`: the first scenario is reported a second time as its own complete test case;
- `writes-no-report`: exit 0 and no report file;
- `hangs` and `record`: unchanged (`record` still runs the real Cucumber).

The accounted outcomes on the is-even fixture feature (`test/acceptance/fixtures/intents/is-even/acceptance.feature`: Even numbers line 3, Odd numbers line 8, Non-integers line 13, three steps each) must be the same on the current pin and on 11a5244; the acceptance table lists them. The ids only need to be unique within the report; their format is free. The fake runner keeps reading the feature named by `KOGEN_ACCEPTANCE_FEATURES` and writing the report at `KOGEN_ACCEPTANCE_REPORT`, with the mode from `KOGEN_TEST_ACCEPTANCE_MODE` or its first argument as today; it may parse the feature itself or use the `@cucumber/gherkin` package reachable through `NODE_PATH=$KOGEN_CUCUMBER`. Kogen's suite only gives it the is-even fixture; Scenario Outlines and Backgrounds need no new support.

No pin change: `cli/go.mod` and `cli/go.sum` are protected and stay unchanged; the adoption moves kogen-verification to 11a5244. No product code, command, flag, limit or verification rule changes; the proof rule is not weakened. The spec scenarios keep their expected feedback unchanged, and the fixture feature stays unchanged.

## Decisions
- The fake runner (test support only) emits source, pickle and test-case steps for every step and exactly one final result per declared test step, so its reports satisfy the complete-evidence rule on the current pin and on 11a5244 alike (source: request)
- Modes that test deliberately bad reports keep producing their bad shape and their expected feedback (source: request)
- No pin change; `cli/go.mod` and `cli/go.sum` stay as they are (source: request)
- No product behaviour change, no weakening of verification's proof rule, no new commands, flags or limits (source: request)

## Source comparison
- Addressed: "the acceptance fake runner reports complete step evidence" — `test/acceptance/fixtures/runners/run.js` emits gherkinDocument steps, pickle steps and test-case steps with exactly one final result per test step; acceptance accounts each report with the real `verify.Account` of the pinned kogen-verification and of `v0.0.0-20261103052035-11a5244e95ee` (11a5244).
- Addressed: the 3 Nov 06:00Z red on `spec/features/05-verifying.feature:54` (`exits-1-all-passed`, feedback "exit 1 with all scenarios passed") — acceptance row `exits-1-all-passed` expects exit 1, `passed,passed,passed` and the problem `exit 1 with all scenarios passed` on both versions.
- Addressed: "Scenarios that test deliberately bad reports keep producing their bad shape on purpose and keep their expected feedback" — rows `reports-undefined` (undefined), `reports-skipped` (skipped), `omits-one-scenario` (missing), `reports-one-twice` (duplicate), `writes-no-report` (report_missing); the spec outline at 05-verifying.feature line 37 stays unchanged.
- Addressed: "the suite passes on the current pin and on 11a5244 alike" — every acceptance row checks both versions; the configured full acceptance and Go checks run on the current pin.
- Addressed: "No pin change in this item: cli/go.mod and cli/go.sum are protected" — both stay unchanged; the 11a5244 driver builds in a temporary module outside the checkout.
- Addressed: "Verification's stronger proof rule stays as it is"; "No product behaviour change ... no new commands, flags or limits" — only the test-support runner changes.
- Omitted: 05-verifying.feature:87 stopping by SIGTERM at load5 56 — the request treats it as a load victim unless it reproduces at low load; no change here.
- Superseded: the earlier 3 Nov 06:50Z attempt's re-pin, dropped by the request (the adoption does it).

## Tests
- The fake runner's reports carry the complete source/pickle/test-step chain with exactly one result per test step, so 11a5244 accounts each mode's intended outcome instead of report_invalid: the acceptance outline over `exits-1-all-passed`, `reports-undefined`, `reports-skipped`, `omits-one-scenario` and `reports-one-twice`, run through the real `verify.Account` of 11a5244 (regression)
- Each mode accounts the same on the current pin as on 11a5244: the same acceptance outline checks both versions (regression)
- Deliberately bad modes keep their bad shape and expected feedback, including `writes-no-report`: the same acceptance outline, plus the unchanged spec outline "A report that is not a clean pass is a failing check" in `spec/features/05-verifying.feature` run by the configured full acceptance (existing)

## Feasibility
- evidence: {"id":"fake-runner-account","kind":"observer","inputs":["features/steps/k_fake_runner_step_evidence_control.cjs","test/acceptance/fixtures/intents/is-even/acceptance.feature"],"observers":["features/steps/k_fake_runner_step_evidence_check.cjs","features/steps/k_fake_runner_step_evidence_driver.go"],"checks":[{"name":"good","command":"node features/steps/k_fake_runner_step_evidence_check.cjs features/steps/k_fake_runner_step_evidence_control.cjs reports-undefined 0 undefined,passed,passed 'undefined: Even numbers (line 3)'","exit":0,"output":"current pin reports-undefined: as expected\n11a5244 reports-undefined: as expected\n"},{"name":"bad","command":"KFR_CONTROL=incomplete node features/steps/k_fake_runner_step_evidence_check.cjs features/steps/k_fake_runner_step_evidence_control.cjs reports-undefined 0 undefined,passed,passed 'undefined: Even numbers (line 3)'","exit":1,"output":"current pin reports-undefined: as expected\n11a5244 reports-undefined: got exit 0, report_invalid,report_invalid,report_invalid, problems report_invalid: Even numbers (line 3) / report_invalid: Odd numbers (line 8) / report_invalid: Non-integers (line 13); want exit 0, undefined,passed,passed, problems undefined: Even numbers (line 3)\n"}]}
- Scratch observations (outside the checkout, from `git archive HEAD`): the driver builds offline from the module cache against both versions in under 1 s warm; the unchanged `run.js` fails five acceptance rows on 11a5244 (all reported scenarios `report_invalid`) and passes `writes-no-report`; a sketched complete-evidence `run.js` passes all six rows on both versions.
