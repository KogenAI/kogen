# Prove the stop scenarios with the lineup baseline

Slug: k-acceptance-models-file
Model: not applicable — this adds acceptance evidence and corrects specification prose; no state machine changes
Acceptance:
- .kogen/intents/k-acceptance-models-file/acceptance.feature
- features/steps/k-acceptance-models-file__suite.js

kogen-coordinator 4826fb1 ("Add opt-in model lineup files", v0.0.0-20261103201314-4826fb104954) puts the team model lineup `.kogen/models.yaml` into the approval baseline, right after `.kogen/project.yaml`, even when the file does not exist. The machine override `.kogen/local/models.yaml` is protected only when a `protect` pattern matches it. With that coordinator, three of kogen's acceptance scenarios failed at their `stdout contains` step at kogen afa32b8:
- `spec/features/02-shaping.feature:138` "An unsupported correction preserves the ready draft" (`shape/refinement_constraint`);
- `spec/features/03-approval-and-build-start.feature:141` "A not-ready Intent has no card and cannot be approved" (`intent/not_ready: the Intent is not ready to build`);
- `spec/features/claude-code-full-lineup.feature:237` "A Shape or Refine checkout index or HEAD mutation stops before publication" (`candidate/baseline_changed`).

**Why they failed.** At afa32b8, `test/acceptance/support/handlers.js` computed the baseline hash itself (`baselineHash`) from a file list without `.kogen/models.yaml`. Its hash for "the caller refines … with its current baseline" and "the caller approves … with the hash of its acceptance baseline" no longer matched kogen's. So kogen correctly refused earlier, with `intent/refinement_stale: is-even is now <sha256>, not <sha256>; …` (scenarios 1 and 3) and `intent/hash_mismatch: is-even is now <sha256>, not <sha256>; …` (scenario 2). The stops the scenarios expect come later and were never reached. kogen reported every stop correctly, so kogen's code has no regression. The suite was fixed in cecf691 "Assert review card content instead of its hash": it now takes the full hash from kogen's own `intent/hash_mismatch` line, so it no longer pins the coordinator's baseline composition. Coordinator 03d7341 (v0.0.0-20261103214825-03d7341feab7, at or after 4826fb1) has been pinned in `cli/go.mod` and `cli/go.sum` since d98cfe0 "Adopt component versions". This Intent therefore does not edit those protected files, and that removes the cause of the previous attempt's `shape/protected_conflict`.

**What this Intent delivers.**
- **Acceptance.** It runs the three scenarios of `test/acceptance` against the release archive built from this checkout (the newest `dist/kogen-*-<platform>.tar.gz`, built by `sh packaging/package.sh` in setup). They must pass, and the release must carry the coordinator version that `cli/go.mod` pins (dated at or after `20261103201314`).
- **Fault test.** It runs the same three scenarios against that release with a wrapper around `bin/kogen` that drops every stdout line containing `shape/refinement_constraint`, `intent/not_ready` or `candidate/baseline_changed`. Each scenario must then fail at its own stop's `stdout contains` step. A pass-through run of the same wrapper must stay green, as a control.
- **Build change: one sentence in `spec/prose/05-verifying.md`.** In the VER-1 line (it starts `**VER-1 — Acceptance baseline.**`), replace the sentence `The baseline is: everything in `.kogen/intents/<slug>/`, every path in its `Acceptance:` list, `.kogen/project.yaml`, and every file matching `protect`.` with exactly:
  `The baseline is: everything in `.kogen/intents/<slug>/`, every path in its `Acceptance:` list, `.kogen/project.yaml`, the team model lineup `.kogen/models.yaml` right after it (even when that file does not exist), and every file matching `protect`. The machine override `.kogen/local/models.yaml` is in the baseline only when a `protect` pattern matches it.`
  The rest of VER-1 is unchanged.

Boundaries:
- Unchanged: kogen's runtime behavior, `cli/` (including the protected `cli/go.mod`, `cli/go.sum`, `cli/loop-pin.json` and vendored loop), `test/acceptance`, and the three scenarios' steps and expected stops. Their expectations already match the intended behavior and pin only the stop line.
- No scenario or step pins coordinator wording beyond those stop lines.
- go test is covered by the configured `go-test` check. The rest of kogen's acceptance (the complete `spec/features` suite) is not run by this Intent's acceptance; see Decisions.

## Decisions
- The three scenarios keep their expected stop codes: `shape/refinement_constraint`, `intent/not_ready: the Intent is not ready to build` and `candidate/baseline_changed`. No coordinator wording beyond the stop line is asserted. (source: request)
- The fault test drops each scenario's stop line from kogen's stdout, and each scenario must then fail at that stop's `stdout contains` step. (source: request)
- The kogen-coordinator pin is at or after 4826fb1: 03d7341, already in `cli/go.mod`. It is checked, not edited. (source: request)
- No kogen code is changed, because the investigation found no regression in how kogen reports the stops. (source: request)
- "The rest of kogen's acceptance passes" needs human evaluation outside this Intent's acceptance. Someone runs the complete suite, `npm test` in `test/acceptance` (or `sh test/suite.sh`), against the Build's release and checks that it is green. (source: request)
  - Why it is not automated here: approval readiness bounds the acceptance command at 120 seconds (docs/using-kogen.md, "Approval step limits"). The configured `cucumber` check runs only `04-building.feature`, and `.kogen/project.yaml` is part of the frozen baseline, so a Build cannot add the suite to the checks.
  - Measurement: `02-shaping.feature` alone (47 scenarios) took 29.3 s wall and about 195 CPU-seconds with `--parallel 8` on this host. The complete suite is about five times larger, so it does not fit.
  - No scenario of this Intent claims that the rest of the suite passes.

## Source comparison
- Problem, the three failing scenarios: identified as 02-shaping.feature:138, 03-approval-and-build-start.feature:141 and claude-code-full-lineup.feature:237. The third is the only one of the cited candidates that expects `candidate/baseline_changed` (at line 255 on HEAD). 02-shaping.feature:380-384/440 expect other lines (`intent/not_ready`, the Quint invariant and probe scenarios), and they pass on HEAD.
- Need 1, why: the suite's self-computed baseline hash omitted `.kogen/models.yaml` (see prose). Observed locally: afa32b8's `test/acceptance` and `spec/features` against the release from this checkout (coordinator 03d7341) failed exactly these three scenarios, with `intent/refinement_stale` ×2 and `intent/hash_mismatch`. HEAD's suite passes them.
- Need 2, same outcome with lineup files: the expectations stay. The acceptance runs them against the lineup-aware coordinator. VER-1 now states the lineup-aware baseline.
- Need 3, a kogen code regression: none found; nothing to name.
- Need 4, bump kogen-coordinator: satisfied by d98cfe0 (v0.0.0-20261103214825-03d7341feab7). The Intent checks the pin and the release binary. Re-editing the protected `cli/go.mod`/`cli/go.sum` is not required, which resolves the retry's `shape/protected_conflict`.
- Acceptance 1:
  - The three scenarios pass with coordinator 03d7341 (Intent scenario 2).
  - go test passes: the configured `go-test` check.
  - The rest of kogen's acceptance passes: human evaluation, for the reason in Decisions.
- Acceptance 2, fault test: Intent scenarios 3 and 4.

## Tests
- The three stop scenarios pass with the lineup-aware coordinator: run them through `test/acceptance` against the release built from this checkout (scenario)
- kogen pins kogen-coordinator at or after 4826fb1 and ships it: the Intent's pin scenario checks `cli/go.mod` and `go version -m` of the release's kogen (integration)
- Each scenario fails when its stop is not reported: the Intent's wrapper scenario drops the stop lines, and its pass-through control stays green (regression)
- VER-1 names `.kogen/models.yaml` in the baseline and `.kogen/local/models.yaml` only via `protect`: the Intent's specification scenario reads the VER-1 line (scenario)
- go test keeps passing: the configured `go-test` check (existing)

## Feasibility
- At HEAD with the release dist/kogen-601f9291-darwin-arm64.tar.gz, `go version -m` showed `github.com/KogenAI/kogen-coordinator v0.0.0-20261103214825-03d7341feab7`. Its README states that the baseline includes `.kogen/models.yaml` right after the project configuration even when absent, and that the local path is not automatically protected (`project/baseline.go` lines 70-71).
- The three scenarios passed through `test/acceptance` against that release in about 6 s and 11 s, run in two groups with `--parallel 3/4`.
- afa32b8's `test/acceptance` and `spec/features` (from `git archive`), against the same release, failed all three at their stop step:
  - `Actual: intent/refinement_stale: is-even is now …` for 02-shaping:138 and claude-code-full-lineup:237;
  - `Actual: intent/hash_mismatch: is-even is now …` for 03:141.
  The assertion message is `stdout did not contain expected text`, from test/acceptance/steps/steps.js:45.
- `02-shaping.feature` alone (47 scenarios, `--parallel 8`) passed in 29.3 s wall, using 79.7 s user and 106.3 s system CPU. This is why the complete suite does not fit the 120 s acceptance step.
- evidence: {"id":"suite-observer","kind":"observer","inputs":["features/steps/k-acceptance-models-file__suite.js"],"observers":["features/steps/k-acceptance-models-file__suite.js"],"checks":[{"name":"good","command":"node features/steps/k-acceptance-models-file__suite.js --control good","exit":0,"output":"observer accepted\n"},{"name":"bad","command":"node features/steps/k-acceptance-models-file__suite.js --control bad","exit":1,"output":"observer rejected\n"}]}
