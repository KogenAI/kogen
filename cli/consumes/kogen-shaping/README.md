# kogen-shaping consumes suite

This package is kogen's side of the two-sided contract with kogen-shaping. It pins exactly what kogen's own non-test code relies on from `github.com/KogenAI/kogen-shaping/shape`, and nothing kogen does not use. kogen-shaping's own tests state what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-shaping/...)
```

## What it pins

kogen's call sites are `cli/engine.go` (`shape.Shape`, `shape.Refine` and `shape.Approve`, each called with the session's context and the session, the exit code used only when the error is nil, `exitFor` in `cli/native.go` mapping the error) and `cli/facts.go` (`shape.Preflight`).

- `api_test.go`: the four functions have the signature `func(context.Context, *sys.Session, <Input>) (int, error)`. `TestInputFields` pins the fields kogen sets and their types: `Project`, `Slug`, `Request`, `RequestPath` and `InstallRoot` are strings, `Tools` is a `verify.Tools`, `Client` a `*provider.Client` and `External` a func that kogen's `externalExecutor` (`func(project.Role) (executor.Executor, error)`) is assignable to (`ShapeInput`, `RefineInput`); `Hash` is a string (`RefineInput`); `Project`, `Slug`, `Hash`, `By` and `Tools` (`ApproveInput`); `Project`, `Slug`, `JSON` and `Checkout` (an `any`) (`PreflightInput`).
- `TestApproveWithoutAHashShowsTheCardWithExit5`: with no `Hash`, `Approve` prints the review card (the Intent, its full SHA-256, the Git identity as approver, `Approve with:` and the command) and returns exit 5 and a nil error. Nothing is approved.
- `TestApproveRunsTheAcceptanceCommandWithTheTools`: the `Tools` are what the readiness check's commands run with (`KOGEN_NODE`, `KOGEN_CUCUMBER`).
- `TestApproveWithTheHashPublishesTheApproval`: a `Hash` of 64 or 6 hex characters that matches publishes `.kogen/local/approvals/fixture.json` (its `sha256`, its `base` HEAD and its `approver`: `By`, or the Git identity when empty) and returns exit 0.
- `TestApproveRefusalsAreSysErrorsWithTheirExit`: refusals are `*sys.Error`s whose `Exit` is Approve's exit and whose rendering starts with `class/reason: `, which `exitFor` prints: `intent/hash_mismatch` 1 (naming the current hash and the card command), `intent/not_found` 2, `environment/not_a_git_repo` 3, `intent/approval_identity_unavailable` 2. `TestApproveInterruptExitsWithTheSignalsCode`: an interrupted session gives `*sys.Interrupted` with exit 143 and nothing is approved.
- `TestPreflightJSONShowsTheCheckoutAndTheBlockers`: with `JSON`, `Preflight` prints one JSON line (`schema_version` 1, `kind` `preflight`, the `Checkout` kogen passed verbatim, and `data` with `slug`, `ready`, the five `checks` and the `blockers`), exit 1 with the `intent/approval_changed` blocker before approval and exit 0 after. `TestPreflightTextReportsTheState`: without `JSON`, `preflight <slug>: blocked` or `ready (observations only)` and one line per check. `TestPreflightUnreadableConfigurationIsExit3`: an unreadable configuration is printed and is exit 3 with a nil error.
- `TestShapeRefusalsAreSysErrorsWithTheirExit`: `environment/not_a_git_repo` 3, `environment/acceptance_unconfigured` 3, `provider/login` 4 (no request is sent), `intent/exists` 5 and `shape/provider_failed` 4 are `*sys.Error`s with Shape's exit.
- `TestShapeAsksTheModelThroughTheClientAndPrintsItsQuestions`: the `Client` reaches the loopback provider named in the session's environment with the login under the session's HOME; the question the model asks is printed after `Questions for fixture:`; exit 5 and a nil error; the `Request` is kept with the pending state. `TestShapeTakesTheRequestAsTheAnswersWhileQuestionsArePending`: the next `Request` is the answers; a line that is not `<n>: ...` is `intent/answers_invalid` with exit 2 and no new model request.
- `TestShapeNamesTheRequestPath`: an untracked `RequestPath` inside the repository is noted (`note: request.md is untracked; ...`), and a failed Shape's rerun hint names that path, or `stdin` when it is empty.
- `TestShapeAsksKogensExecutorForAnExternalShapeRole` and `TestRefineAsksKogensExecutorForAnExternalShapeRole`: for a shape role with `executor: claude-code`, `External` is called once with that role (before any login is asked for); its error is the refusal, and no executor is `executor/unavailable` with exit 1, also when `External` is nil.
- `TestRefineRefusalsAreSysErrorsWithTheirExit`: `intent/not_found` 2, `intent/refinement_hash` 2 (a hash shorter than 64 characters), `intent/refinement_stale` 1 (naming the current hash and the card command) and `provider/login` 4.
- `TestShapeInterruptExitsWithTheSignalsCode` and `TestRefineInterruptExitsWithTheSignalsCode`: an interrupted session gives `*sys.Interrupted` with the signal's exit (143, 130), and nothing is written.

## Isolation

- `TestMain` removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic and live under `t.TempDir()`: a Git repository with its own identity, no signing and an empty hooks folder, a committed Intent, an acceptance script that replays a prepared Cucumber Messages report (no Node or Cucumber runs), and a HOME of the fixture's own with a fake ChatGPT login.
- The model is a loopback `httptest` server on a free port, reached through `KOGEN_PROVIDER_URL` in the session's environment, that plays scripted streamed answers. No real model runs and nothing reaches the network.
- The suite imports only the standard library, `shape`, and, as fixtures, kogen-coordinator `project`, kogen-executor `executor`, kogen-verification `verify` and kogen-loop `provider` and `sys`. It imports no `kogen/...` package, uses no fixed port and no host path, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness`, `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does. Each identifier is mapped to its tests in the Inventory below; the suite references every one, and no other identifier of `shape` except `shape.External`, the named type of the `External` fields.

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `shape.Approve` | `cli/engine.go` | the signature pin in `api_test.go`, every `TestApprove...` |
| `shape.ApproveInput` | `cli/engine.go` | `TestInputFields`, every `TestApprove...` |
| `shape.ApproveInput.By` | `cli/engine.go` | `TestInputFields`, `TestApproveWithTheHashPublishesTheApproval` |
| `shape.ApproveInput.Hash` | `cli/engine.go` | `TestInputFields`, `TestApproveWithTheHashPublishesTheApproval`, `TestApproveRefusalsAreSysErrorsWithTheirExit` |
| `shape.ApproveInput.Project` | `cli/engine.go` | `TestInputFields`, every `TestApprove...` |
| `shape.ApproveInput.Slug` | `cli/engine.go` | `TestInputFields`, every `TestApprove...` |
| `shape.ApproveInput.Tools` | `cli/engine.go` | `TestInputFields`, `TestApproveRunsTheAcceptanceCommandWithTheTools` |
| `shape.Preflight` | `cli/facts.go` | the signature pin in `api_test.go`, every `TestPreflight...` |
| `shape.PreflightInput` | `cli/facts.go` | `TestInputFields`, every `TestPreflight...` |
| `shape.PreflightInput.Checkout` | `cli/facts.go` | `TestInputFields`, `TestPreflightJSONShowsTheCheckoutAndTheBlockers` |
| `shape.PreflightInput.JSON` | `cli/facts.go` | `TestInputFields`, `TestPreflightJSONShowsTheCheckoutAndTheBlockers`, `TestPreflightTextReportsTheState` |
| `shape.PreflightInput.Project` | `cli/facts.go` | `TestInputFields`, every `TestPreflight...` |
| `shape.PreflightInput.Slug` | `cli/facts.go` | `TestInputFields`, every `TestPreflight...` |
| `shape.Refine` | `cli/engine.go` | the signature pin in `api_test.go`, every `TestRefine...` |
| `shape.RefineInput` | `cli/engine.go` | `TestInputFields`, every `TestRefine...` |
| `shape.RefineInput.Client` | `cli/engine.go` | `TestInputFields`, `TestRefineRefusalsAreSysErrorsWithTheirExit` |
| `shape.RefineInput.External` | `cli/engine.go` | `TestInputFields`, `TestRefineAsksKogensExecutorForAnExternalShapeRole` |
| `shape.RefineInput.Hash` | `cli/engine.go` | `TestInputFields`, `TestRefineRefusalsAreSysErrorsWithTheirExit` |
| `shape.RefineInput.InstallRoot` | `cli/engine.go` | `TestInputFields`, `TestRefineRefusalsAreSysErrorsWithTheirExit` |
| `shape.RefineInput.Project` | `cli/engine.go` | `TestInputFields`, every `TestRefine...` |
| `shape.RefineInput.Request` | `cli/engine.go` | `TestInputFields`, `TestRefineRefusalsAreSysErrorsWithTheirExit` |
| `shape.RefineInput.RequestPath` | `cli/engine.go` | `TestInputFields`, `TestRefineRefusalsAreSysErrorsWithTheirExit` |
| `shape.RefineInput.Slug` | `cli/engine.go` | `TestInputFields`, every `TestRefine...` |
| `shape.RefineInput.Tools` | `cli/engine.go` | `TestInputFields`, `TestRefineRefusalsAreSysErrorsWithTheirExit` |
| `shape.Shape` | `cli/engine.go` | the signature pin in `api_test.go`, every `TestShape...` |
| `shape.ShapeInput` | `cli/engine.go` | `TestInputFields`, every `TestShape...` |
| `shape.ShapeInput.Client` | `cli/engine.go` | `TestInputFields`, `TestShapeAsksTheModelThroughTheClientAndPrintsItsQuestions` |
| `shape.ShapeInput.External` | `cli/engine.go` | `TestInputFields`, `TestShapeAsksKogensExecutorForAnExternalShapeRole` |
| `shape.ShapeInput.InstallRoot` | `cli/engine.go` | `TestInputFields`, `TestShapeRefusalsAreSysErrorsWithTheirExit` |
| `shape.ShapeInput.Project` | `cli/engine.go` | `TestInputFields`, every `TestShape...` |
| `shape.ShapeInput.Request` | `cli/engine.go` | `TestInputFields`, `TestShapeTakesTheRequestAsTheAnswersWhileQuestionsArePending` |
| `shape.ShapeInput.RequestPath` | `cli/engine.go` | `TestInputFields`, `TestShapeNamesTheRequestPath` |
| `shape.ShapeInput.Slug` | `cli/engine.go` | `TestInputFields`, every `TestShape...` |
| `shape.ShapeInput.Tools` | `cli/engine.go` | `TestInputFields`, every `TestShape...` |
