# Name the first feature command after init

Slug: k-cli-init-success-names-first-intent-command
Model: not applicable — conditional CLI copy adds no meaningful state
Acceptance:
- .kogen/intents/k-cli-init-success-names-first-intent-command/acceptance.feature
- features/steps/k-cli-init-success-names-first-intent-command__cli.js

End ready `kogen init` output with exactly one `Next: kogen intent shape <slug> <request-file>` line after the readiness lines, on initial setup and already-configured runs. Add no success hint if readiness fails or init already prints a missing-acceptance or missing-checks Next hint. Preserve exit status, readiness details and fixes, and existing Next hints. Update both init output blocks in docs/getting-started.md and their surrounding description. Retain the request-file-outside-repository guidance and the instructions for answering Shape with `<n>: <letter>` lines on stdin or in a file, followed by approve and build. No provider or dependency changes.

## Decisions
- Use the exact requested command and placeholders on the final success line (source: request)
- Preserve existing setup hints even when a later readiness line fails; suppress the new success hint on failure. Existing empty-repository output already prints setup hints before its failure/fix suffix (evidence: .kogen/intents/k-doctor-fold/acceptance.feature; cli/engine.go; cli/readiness.go) (source: request)
- Preserve informational readiness failures without changing init's exit status; the delivered missing-login scenario explicitly expects zero (evidence: cli/readiness.go; .kogen/intents/k-doctor-fold/acceptance.feature) (source: request)
- Preserve four ok readiness lines on a valid configuration with missing acceptance or checks; do not append the success hint to the existing setup hint (evidence: cli/readiness/readiness.go; .kogen/intents/k-doctor-fold/acceptance.feature) (source: request)
- Use the existing packaged CLI support, isolated homes and synthetic logins for local acceptance (evidence: features/steps/go_driver_support.js; features/steps/k_doctor_fold_steps.js) (source: request)
- Qualify the observer with its good and bad controls: the executed good invocation printed accepted, the bad invocation printed rejected with exit one (evidence: ran `"$KOGEN_NODE" features/steps/k-cli-init-success-names-first-intent-command__cli.js good; "$KOGEN_NODE" features/steps/k-cli-init-success-names-first-intent-command__cli.js bad; test "$?" -eq 1`) (source: request)

## Source comparison
- Addressed: Request Problem and Need; the outcome above and ready-run scenario replace the silent all-ok suffix with the exact first-feature command and its requested placeholders.
- Addressed: synthetic acceptance for clean home, saved login, Git identity, one commit, passing check and repeated init; the local fixtures exercise the packaged CLI. Missing-login, missing-acceptance and missing-checks scenarios preserve the current outcomes (evidence: cli/readiness.go; cli/readiness/readiness.go; .kogen/intents/k-doctor-fold/acceptance.feature).
- Addressed: both docs/getting-started.md init output blocks; the guide scenario compares their suffix to real CLI output. Preserve their earlier setup excerpts and the outside-repository request, stdin/file answers, approve and build guidance.
- Addressed: delivery note 7 Nov 07:05Z; inspect current source and tests before preserving behavior and update delivered tests of changed successful output in this same implementation. In particular, do not rewrite the delivered missing-checks or missing-login expectations as new failures (evidence: .kogen/intents/k-doctor-fold/acceptance.feature; cli/readiness.go).
- Conflicting wording resolved by the explicit preservation requirement: Need says no Next on a readiness failure and also says existing Next lines are unchanged. Keep existing setup hints before readiness and leave the fail/fix suffix last, never adding the new success hint. This preserves the actual supplied baseline rather than repeating the previous builder-reported contradiction (evidence: .kogen/intents/k-doctor-fold/acceptance.feature).
- Omitted deliberately: no new settings, provider calls, authentication or workflow changes, and no resumption of prior stopped work. None is required by this output hint.

## Tests
- Initial and repeated ready init end with one exact command after readiness: isolated packaged-CLI scenario and focused implementation regression coverage (scenario)
- Failed readiness leaves failure/fix last and preserves status: missing-login packaged-CLI scenario (regression)
- Existing missing-acceptance and missing-checks hints remain without a second hint: separate configuration-omission scenarios (scenario)
- Both guide init blocks show the new real suffix: compare their final lines to real CLI output and update delivered documented-output checks for changed output (integration)

## Feasibility
- Observer good/bad results were inspected in the scratch probe cited in Decisions. The following native obligations replay the same final observer bytes separately.
- evidence: {"id":"report-observer","kind":"observer","inputs":["features/steps/k-cli-init-success-names-first-intent-command__cli.js"],"observers":["features/steps/k-cli-init-success-names-first-intent-command__cli.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k-cli-init-success-names-first-intent-command__cli.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k-cli-init-success-names-first-intent-command__cli.js bad","exit":1,"output":"rejected\n"}]}
