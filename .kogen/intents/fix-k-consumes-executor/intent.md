# Record that the executor finding is not in kogen

Slug: fix-k-consumes-executor
Model: not applicable — no code, test or documentation in this checkout changes, so there is no state
Acceptance:
- .kogen/intents/fix-k-consumes-executor/acceptance.feature
- features/steps/fix-k-consumes-executor__absent.js

The review finding concerns `TestRoleConsumption` and `TestProviderConsumption`. It says they assign struct fields and read them back, so they can fail only at compile time, and that the README "Assertion" column overstates their coverage. The Need's first step is to show the finding on current main. If it does not hold there, the outcome is to stop and report that it does not reproduce, with no code change. On this checkout's current main it does not hold, so this Intent records that report.

What the shaping inspection found:
- This kogen checkout has neither test. No `*_test.go` file under `cli/` defines them, and no Markdown file has a table column headed "Assertion". kogen's own consumes suites under `cli/consumes/` have different tests, and their READMEs use prose lists, not an Assertion table.
- The tests and the table belong to the separate kogen-executor repository: `consumes/kogen-coordinator/coordinator_test.go` (`TestRoleConsumption`), `consumes/kogen-loop/loop_test.go` (`TestProviderConsumption`) and `consumes/README.md`. They first appear in module version `v0.0.0-20261104084012-b2ffb64382e8`.
- The finding does hold in kogen-executor, which is where it has to be fixed:
  - `TestRoleConsumption` builds a `project.Role` literal and reads the same four fields back.
  - `TestProviderConsumption` really checks the `provider.ResponseBudget` default of 30m and the `provider.Name` routing. Its "writable 10m" `Client.ResponseBudget` check and its `Response` Usage/Known "known/unknown counts" check are field round trips.
- kogen pins kogen-executor at `v0.0.0-20261104021843-9021591798ac` in `cli/go.mod`. That version predates the consumes suite and has no `consumes` directory.
- Kogen does not vendor kogen-executor; only kogen-loop is copied, under `cli/third_party/kogen-loop`. So kogen's tree has no file whose edit could make those tests exercise producer behaviour or correct that README.

Neither path the Need allows can be taken in this repository: tests that exercise real producer behaviour, or a corrected README "Assertion" column. Neither path waits on a kogen pin move. Moving `cli/go.mod` would not make kogen-executor's files editable here, and producer pins move only by adoption, never in this Build. The fix needs its own delivery in a kogen-executor checkout, against the producer versions that repository pins: kogen-coordinator `v0.0.0-20261104010828-f15509472852` and kogen-loop `v0.0.0-20261104002337-25d87c2177c3`.

Boundaries. The Build changes no file outside this Intent's own directory and step file. kogen's code, tests, READMEs, `cli/go.mod`, `cli/go.sum`, `cli/loop-pin.json` and `cli/third_party/kogen-loop/` stay byte-identical. Every existing test stays green. Nothing is added, replaced or removed.

## Decisions
- Take the Need's stop outcome: on this checkout's current main the named tests and the "Assertion" column do not exist, so the finding does not reproduce here and there is no code change (source: request)
- Producer pins stay where they are; `cli/go.mod` and `cli/go.sum` are not edited (source: request)
- The fix itself belongs in the kogen-executor repository and needs its own delivery there; no kogen pin move is what it waits for (source: request)

## Source comparison
- addressed: "First show it ... If that does not hold, stop and report that it does not reproduce (no code change)" → this Intent is that report. Scenario 1 shows that neither named test exists in any Go test file under `cli`. Scenario 2 shows that no Markdown file in the checkout has an "Assertion" column.
- addressed: "Where: TestRoleConsumption, TestProviderConsumption" → both names are literal in scenario 1.
- addressed: retry cause (the tests live in kogen-executor `consumes/kogen-coordinator/coordinator_test.go`, `consumes/kogen-loop/loop_test.go` and `consumes/README.md`) → scenario 3 pins the kogen-executor version `cli/go.mod` requires (`v0.0.0-20261104021843-9021591798ac`) and shows that the pinned module has no `consumes` directory.
- addressed: changed input "cli/go.mod and cli/go.sum are protected ... Work with the producer versions pinned now" → no pin edit; scenario 3 reads the pin as it is now.
- superseded for this repository: "Then fix it ... Exercise real producer behavior, or correct the README" and the changed input's README fallback → no file of this checkout carries either. The prose names the kogen-executor files and versions where that fix belongs.
- addressed: "Keep every existing test green; no unrelated changes" → no file outside the Intent changes; the configured checks (`go-test`, `cucumber`, `spec` and the others) stay as they are.

## Tests
- none: no executable behaviour, test or documentation in this checkout changes. The acceptance scenarios observe that the named tests, the "Assertion" column and a pinned executor `consumes` directory are absent, so they pass before and after the Build.

## Feasibility
- none
