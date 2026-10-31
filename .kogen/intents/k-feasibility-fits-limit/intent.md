# Reject shapes that exceed approval limits

Slug: k-feasibility-fits-limit
Model: not applicable — this wires existing bounded command execution into shaping readiness, without a new product state machine
Acceptance:
- .kogen/intents/k-feasibility-fits-limit/acceptance.feature
- features/steps/feasibility_fits_limit_steps.js

Do not publish a shaped Intent when its declared feasibility commands or acceptance command time out under the limits approval actually enforces on the shaping host. Return actionable feedback to the shaping agent during submission so it can adjust the evidence or acceptance. Ordinary missing-feature accounted red remains allowed; a timeout is not accounted red and cannot be acknowledged into readiness. Preserve approval's existing limits and behavior: feasibility probes have the existing 300-second command bound, acceptance has the existing 120-second per-command step bound. These are not a total conversation or suite budget. No new command, flag, option, retry, timeout increase or configurable limit.

## Decisions
- Reject over-limit feasibility and acceptance during Shape, rather than learning of it only at approve. Identify the timed-out observer/declaration and check (good or bad), or acceptance step, and its applicable limit in feedback. (source: request)
- Observers that fit retain the existing readiness behavior, including valid nonzero bad-control exits. Commands that collectively exceed a limit but individually fit are not rejected for their combined duration. (source: request)
- Measure actual execution on the shaping host, not static command-text estimates; use the existing process-group watchdog and preserve normal cleanup and exact-candidate readiness rules. (source: request)

## Source comparison
- addressed: request Need and Acceptance evidence by bounded Shape submission readiness, named observer/limit feedback, rejection without publication or reusable ready evidence, and successful timely controls; see outcome, Decisions and acceptance scenarios.
- addressed: later same-day acceptance extension by a 120-second bound on the entire configured acceptance command during Shape, not a fresh allowance per Gherkin step; see acceptance timeout regression. Approval limits/behavior stay unchanged.
- addressed: S-FIXTURE-READINESS observers `node features/steps/s-fixture-readiness-control.cjs good|bad` historically timed out near 300 seconds with exit 143; reproduce this over-limit observer class with small local process fixtures and contracted existing test deadlines, not Studio packaging/PostgreSQL or external downloads. Preserve rejection even if an exit happens to equal the declaration's expected exit.
- addressed: K-CHECKTIME-SHARD (ten full race passes), K-GO-TEST-PARALLEL (395-second kogen/build acceptance), and L-SHELL-HANG reproduce the long-running acceptance class; executable tests use local sleeping/blocking acceptance processes instead of those expensive historical workloads.
- omitted: replaying three historical MacBook approval attempts (12:44Z, 13:04Z, 14:16Z, feasibility 601.8/573.2/602.0 seconds), host load and private attempt directories is diagnostic history, not required runtime input. No limit increases, retries, provider changes or new settings are authorized.

## Tests
- Over-limit feasibility cannot become shaped and names the observer/check and 300-second limit: TestShapeFeasibilityFitsLimit through native Shape submission with local processes (regression)
- Timely good/bad controls retain acceptance and limits are per command: TestShapeTimelyEvidenceFitsLimit through native Shape submission (integration)
- Over-limit acceptance cannot become shaped and names acceptance and 120-second limit, including a process that hangs without producing a report: TestShapeAcceptanceFitsLimit through native Shape submission (regression)
- Timely acceptance, including accounted missing-feature red, retains existing publication/acknowledgment behavior: TestShapeTimelyAcceptanceFitsLimit (integration)
- Approval limits, watchdog behavior and refusal diagnostics remain unchanged: existing approval deadline and probe deadline tests (existing)

Implementation tests named above belong in cli/shape and are not protected acceptance artifacts. Exercise the native submission path using existing scripted-provider/test fixtures, real temporary Git projects and real local child processes. Contract existing test deadlines to keep all four focused tests together below 120 seconds, restoring hooks afterward; do not add a production setting or wait 300 seconds. Assert production constants separately (300 seconds for feasibility and 120 seconds for acceptance). Test just-below and at-bound timely outcomes with the existing runner hooks where deterministic, plus actual over-bound process termination. A timeout must not publish files, record reusable ready evidence, or be waived by exact-red acknowledgment; feedback must reach the scripted shaper and allow a corrected timely submission to succeed. Exercise both observer good and bad timeouts without masking one behind the other. Keep approval regression coverage unchanged. Do not modify protected third-party process code; use the existing verify and shape entry points/hooks.

## Feasibility
- none
