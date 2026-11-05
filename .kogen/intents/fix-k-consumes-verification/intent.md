# Record the verification finding is not in kogen

Slug: fix-k-consumes-verification
Model: not applicable — no code, test or documentation in this checkout changes, so there is no state
Acceptance:
- .kogen/intents/fix-k-consumes-verification/acceptance.feature
- features/steps/fix-k-consumes-verification__absent.js

The review finding is about `consumes/kogen-loop/sys_test.go`. It makes four claims:
- `errors.Is(fmt.Errorf("%w",X),X)` tests only the standard library.
- `TestTmpPath`'s `filepath.Base(p)` check is always true.
- `Options.Context`, `RefuseForeignKill` and cleanup are claimed but never asserted.
- `TestCommand` compares `$PWD` with `t.TempDir()`, which fails on macOS (/var → /private/var).

The Need's first step is to show the finding on current main. If it does not hold there, the outcome is to stop and report that it does not reproduce, with no code change. On this checkout's current main it does not hold, so this Intent records that report.

What the shaping inspection found:
- This kogen checkout has no `consumes/kogen-loop/sys_test.go`. kogen's own suite for kogen-loop is `cli/consumes/kogen-loop/` (`sys_run_test.go`, `sys_error_test.go`, `sys_session_test.go` and others). No Go test file under `cli` defines `TestCommand`, `TestInterruptAndError` or `TestTmpPath`, and no Go file under `cli` has any of the cited expressions. kogen's own consumes tests already resolve temporary directories with `filepath.EvalSymlinks` (`cli/consumes/kogen-loop/helper_test.go`, `cli/consumes/kogen-loop/sys_run_test.go`). No Markdown file in the checkout has the "Direct assertions" table column that the finding's README uses.
- The file belongs to the separate kogen-verification repository. kogen pins that repository at `github.com/KogenAI/kogen-verification v0.0.0-20261105151659-f5babef00998` in `cli/go.mod`. In that pinned module, `consumes/kogen-loop/sys_test.go` (package `kogenloop_test`) has every cited defect:
  - `errors.Is(fmt.Errorf("wrap: %w", sys.ErrTimeoutObservation), sys.ErrTimeoutObservation)`.
  - `filepath.Base(p) == ""`.
  - `r.Output != "extra:"+dir+":err"`, with `dir := t.TempDir()` and no `EvalSymlinks`.
  - It never sets `Options.Context` or `RefuseForeignKill`, although its `consumes/README.md` lists both among the consumed members.
  So the finding holds in kogen-verification, and that is where it has to be fixed.
- Kogen does not vendor kogen-verification; only kogen-loop is copied, under the protected `cli/third_party/kogen-loop`. `go test ./...` in `cli` does not run kogen-verification's tests. So kogen's tree has no file whose edit could fix that test or correct that README.

Neither path the Need allows can be taken in this repository: tests that fail on the broken behaviour (assert the sentinel is produced, check the `TmpPath` prefix and distinctness, use `EvalSymlinks`), or a corrected README "Assertion" column. Neither path waits on a kogen pin move. Moving `cli/go.mod` would not make kogen-verification's files editable here, and producer pins move only by adoption, never in this Build. The fix needs its own delivery in a kogen-verification checkout, against the producer versions that repository pins: kogen-loop `v0.0.0-20261104002337-25d87c2177c3` and kogen-coordinator `v0.0.0-20261104010828-f15509472852`.

Boundaries. The Build changes no file outside this Intent's own directory and step file. kogen's code, tests, READMEs, `cli/go.mod`, `cli/go.sum`, `cli/loop-pin.json` and `cli/third_party/kogen-loop/` stay byte-identical. Every existing test stays green. Nothing is added, replaced or removed.

## Decisions
- Take the Need's stop outcome: the finding does not reproduce in this kogen checkout, so the Intent is a no-code-change report (decision: D1, round 1) (constraint: Do not edit cli/go.mod, cli/go.sum, cli/loop-pin.json or cli/third_party/kogen-loop) (constraint: The Build changes only the Intent directory and its step file) (evidence: cli/go.mod; cli/consumes/kogen-loop/sys_run_test.go; cli/consumes/kogen-loop/helper_test.go; .kogen/intents/fix-k-consumes-executor/intent.md; features/steps/fix-k-consumes-executor__absent.js) (assumption: The claims that no Go file under cli defines the named tests or has the cited expressions come from session-local searches, not Kogen probes; acceptance scenarios 1-3 check them.) (source: request)
- The fix belongs in a kogen-verification delivery against its own pins; no kogen pin move is involved (decision: D2, round 1) (evidence: cli/go.mod) (assumption: The module-cache contents were read outside Kogen's probe record. Acceptance scenario 4 checks them through go list -m, which assumes the pinned module resolves in the acceptance environment, as the committed fix-k-consumes-executor step already did.) (source: request)
- Producer pins stay where they are; `cli/go.mod` and `cli/go.sum` are not edited (source: request)

## Source comparison
- addressed: "First show it ... If that does not hold, stop and report that it does not reproduce (no code change)" → this Intent is that report.
  - Scenario 1 shows that no Go test file under `cli` defines `TestCommand`, `TestInterruptAndError` or `TestTmpPath`.
  - Scenario 2 shows that no Go file under `cli` has any of the three cited expressions.
  - Scenario 3 shows that no Markdown file has the "Direct assertions" column.
- addressed: "Where: consumes/kogen-loop/sys_test.go" and the retry cause (the file lives in kogen-verification) → scenario 4 reads the kogen-verification pin that `cli/go.mod` requires now (`v0.0.0-20261105151659-f5babef00998`). It shows that the resolved module's `consumes/kogen-loop/sys_test.go` has the cited expressions and never sets `RefuseForeignKill` or `Context:`, while its `consumes/README.md` claims `RefuseForeignKill`. That is, the finding holds in kogen-verification.
- addressed: changed input "cli/go.mod and cli/go.sum are protected ... Work with the producer versions pinned now" → no pin edit; scenario 4 reads the pin as it is now.
- superseded for this repository: "Then fix it ... Assert the sentinel is produced. Check the prefix and distinctness. Use EvalSymlinks" and the changed input's README fallback → no file of this checkout carries either. The prose names the kogen-verification files and versions where that fix belongs, and states that no kogen pin move is involved.
- addressed: "Keep every existing test green; no unrelated changes" → no file outside the Intent changes; the configured checks (`go-test`, `cucumber`, `spec` and the others) stay as they are.

## Tests
- none: no executable behaviour, test or documentation in this checkout changes. The acceptance scenarios observe that the cited tests and expressions are absent from kogen and present in the pinned kogen-verification module, so they pass before and after the Build.

## Feasibility
- none
