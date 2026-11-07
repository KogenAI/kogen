# kogen-build consumes suite

This package is kogen's side of the two-sided contract with kogen-build. It pins exactly what kogen's own non-test code relies on from `github.com/KogenAI/kogen-build/build`, and nothing kogen does not use. kogen-build's own tests state what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-build/...)
```

## What it pins

kogen's call sites are `cli/engine.go` (`build.Build`, `build.Resume` and `build.Recover` with the session's context, the session and an input; the exit code is used only when the error is nil, and `exitFor` in `cli/native.go` maps the error) and `cli/main.go` (`readDiagnostic` builds a `build.Diagnostic`).

- `api_test.go`: `build.Build`, `build.Resume` and `build.Recover` are `func(context.Context, *sys.Session, <input>) (int, error)`. `TestInputFields`: `build.Deps` has `Client` (`*provider.Client`), `Tools` (`verify.Tools`) and `External` (`func(project.Role) (executor.Executor, error)`); `build.Input` has the embedded `Deps`, `Project`, `Slug` (strings) and `Context` (`*build.Diagnostic`); `build.ResumeInput` has the embedded `Deps`, `Project` and `ID`; `build.RecoverInput` has `Project`, `ID` and `Output`; `build.Diagnostic` has `Text`, `SourcePath` and `SHA256` (strings).
- `TestExternalIsTheExecutorFactoryOfBuildRoles`: a build role that selects `executor: claude-code` calls `Deps.External` with that role, and the error it returns stops the Build before any run exists, as a refusal whose exit `exitFor` returns.
- `TestBuildLandsOneCommitAndReturnsExitZero`: a landed Build is exit 0 and a nil error, reported on stdout (`landed fixture <sha8> (Build <id>)`, the checks and the review), with exactly one commit and the `Kogen-Intent: fixture` trailer. `Deps.Client` asks the model (a builder and a review request) and `Deps.Tools.Node` is the `KOGEN_NODE` the acceptance command runs with.
- `TestBuildCarriesTheDiagnosticIntoTheBuildersConversation`: `Input.Context` reaches the builder's request with its text and its source label, and the Build lands.
- `TestBuildRefusesInvalidDiagnosticData`: diagnostic data with a wrong SHA-256, a relative or empty label, blank text, invalid UTF-8 or more than 262144 bytes is refused as `intent/context_unavailable` with exit 2, before any run or request.
- `TestBuildRefusalsBeforeARunAreSysErrorsWithTheirExit`: a failed start check is a `*sys.Error` whose `Exit` is Build's exit and whose rendering `exitFor` prints: `intent/not_approved` 5, `intent/changed_since_approval` 1, `intent/not_found` 2, `environment/dirty_tree` 5, `environment/git_identity_missing` 3, `environment/git_operation_in_progress` 3, `provider/login` 4. No run and no model request exist.
- `TestBuildStoppedByTheProviderIsANonzeroExitWithoutAnError`: once a run exists, a stop that is not an interrupt is reported on stdout (`failed fixture: refused (Build <id>)`, `provider/refused:`) and returned as a nonzero exit (4) with a nil error; HEAD is unchanged.
- `TestInterruptedBuildReturnsTheSignalsExitCode`: an interrupt during the model request is a `*sys.Interrupted` whose `ExitCode` is 130 (SIGINT), 143 (SIGTERM) or 129 (SIGHUP), the edits stay in place and stdout names the Build.
- `TestResumeContinuesAStoppedBuildAndLandsWithExitZero`: `Resume` takes the Build's id and the `Deps`, continues as a new run (the client asks the model again), lands with exit 0 and a nil error, and resuming the landed run is exit 0 with `Build <id> already landed <commit>`.
- `TestResumeRefusalsAreSysErrorsWithTheirExit`: a malformed id is refused as `candidate/resume_unsupported: "<id>" is not a Build id; ...` and a well-formed id with no recorded Build as `candidate/resume_unsupported: Build <id>: no Build with this id in this checkout; ...`, both naming `kogen intent list` and the notice `no newly created Build run`; a checkpoint whose HEAD moved is `candidate/resume_refused`. All are `*sys.Error`s with exit 1; the first two create no run, the last sends no request.
- `TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation`: `Recover` takes the project, the id and a new directory outside the checkout, returns exit 0 and a nil error, publishes the archive with its `manifest.json` there and restores the implementation the builder left. The blocked Build the test starts from is made as kogen-build requires from 8852812: the fixture adds a project check that is red while a flag file exists, the builder writes the candidate and raises the flag in its first round so the verification pass is red, and reports the blocker in the next round, so the claim is grounded in that failing verification.
- `TestRecoverRefusalsAreSysErrorsWithTheirExit`: `candidate/recovery_unsupported` (a malformed id, `"<id>" is not a Build id`; a well-formed id with no recorded Build, `no Build with this id in this checkout`, both naming `kogen intent list`; a recorded Build whose `checkpoint.json` is removed, `unknown checkpoint: absent checkpoint`) and `candidate/recovery_refused` (output inside the checkout, output already existing) are `*sys.Error`s with exit 1, which kogen's `exitFor` returns whatever code `Recover` returned beside them; nothing is written.

## Isolation

- `TestMain` removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic and live under `t.TempDir()`: a Git repository with its own identity, no signing and an empty hooks folder, an approved Intent with one acceptance feature and one step file, an acceptance script that reports every scenario passed (the recover tests' fixture adds one project check that is red while a flag file exists, which grounds the builder's blocker claim in a failing verification pass, as kogen-build requires from 8852812), and a HOME of the fixture's own with a fake ChatGPT login. Every test has its own.
- The model and the sign-in are a loopback `httptest` server on a free port, reached through `KOGEN_PROVIDER_URL` and `KOGEN_AUTH_URL` in the session's environment, that plays scripted streamed answers (builder tool calls, review verdicts, a refusal, a held-open request). No real model runs and nothing reaches the network.
- The suite imports only the standard library, `build` and, as fixtures, kogen-coordinator `project` (configuration, Intent files and approval of the fixture project), kogen-executor `executor` (the `External` function's type and a refusal), kogen-verification `verify` (`Tools`) and kogen-loop `provider` and `sys` (the client and the session). It imports no `kogen/...` package, uses no fixed port and no host path, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness` and `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does. Each identifier is mapped to its tests in the Inventory below; the suite references every one and no other identifier of `build`.

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `build.Build` | `cli/engine.go` | the signature pin in `api_test.go`, `TestBuildLandsOneCommitAndReturnsExitZero`, `TestBuildRefusalsBeforeARunAreSysErrorsWithTheirExit`, `TestBuildStoppedByTheProviderIsANonzeroExitWithoutAnError`, `TestInterruptedBuildReturnsTheSignalsExitCode` |
| `build.Deps` | `cli/engine.go` | `TestInputFields`, `TestBuildLandsOneCommitAndReturnsExitZero`, `TestResumeContinuesAStoppedBuildAndLandsWithExitZero` |
| `build.Deps.Client` | `cli/engine.go` | `TestInputFields`, `TestBuildLandsOneCommitAndReturnsExitZero`, `TestResumeContinuesAStoppedBuildAndLandsWithExitZero` |
| `build.Deps.External` | `cli/engine.go` | `TestInputFields`, `TestExternalIsTheExecutorFactoryOfBuildRoles` |
| `build.Deps.Tools` | `cli/engine.go` | `TestInputFields`, `TestBuildLandsOneCommitAndReturnsExitZero` |
| `build.Diagnostic` | `cli/engine.go`, `cli/main.go` | `TestInputFields`, `TestBuildCarriesTheDiagnosticIntoTheBuildersConversation`, `TestBuildRefusesInvalidDiagnosticData` |
| `build.Diagnostic.SHA256` | `cli/main.go` | `TestInputFields`, `TestBuildRefusesInvalidDiagnosticData` |
| `build.Diagnostic.SourcePath` | `cli/main.go` | `TestInputFields`, `TestBuildCarriesTheDiagnosticIntoTheBuildersConversation`, `TestBuildRefusesInvalidDiagnosticData` |
| `build.Diagnostic.Text` | `cli/main.go` | `TestInputFields`, `TestBuildCarriesTheDiagnosticIntoTheBuildersConversation`, `TestBuildRefusesInvalidDiagnosticData` |
| `build.Input` | `cli/engine.go` | `TestInputFields`, the signature pin in `api_test.go`, every Build test |
| `build.Input.Context` | `cli/engine.go` | `TestInputFields`, `TestBuildCarriesTheDiagnosticIntoTheBuildersConversation`, `TestBuildRefusesInvalidDiagnosticData` |
| `build.Input.Deps` | `cli/engine.go` | `TestInputFields`, every Build test |
| `build.Input.Project` | `cli/engine.go` | `TestInputFields`, every Build test |
| `build.Input.Slug` | `cli/engine.go` | `TestInputFields`, every Build test |
| `build.Recover` | `cli/engine.go` | the signature pin in `api_test.go`, `TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation`, `TestRecoverRefusalsAreSysErrorsWithTheirExit` |
| `build.RecoverInput` | `cli/engine.go` | `TestInputFields`, the signature pin in `api_test.go`, every Recover test |
| `build.RecoverInput.ID` | `cli/engine.go` | `TestInputFields`, every Recover test |
| `build.RecoverInput.Output` | `cli/engine.go` | `TestInputFields`, `TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation`, `TestRecoverRefusalsAreSysErrorsWithTheirExit` |
| `build.RecoverInput.Project` | `cli/engine.go` | `TestInputFields`, every Recover test |
| `build.Resume` | `cli/engine.go` | the signature pin in `api_test.go`, `TestResumeContinuesAStoppedBuildAndLandsWithExitZero`, `TestResumeRefusalsAreSysErrorsWithTheirExit` |
| `build.ResumeInput` | `cli/engine.go` | `TestInputFields`, the signature pin in `api_test.go`, every Resume test |
| `build.ResumeInput.Deps` | `cli/engine.go` | `TestInputFields`, every Resume test |
| `build.ResumeInput.ID` | `cli/engine.go` | `TestInputFields`, every Resume test |
| `build.ResumeInput.Project` | `cli/engine.go` | `TestInputFields`, every Resume test |
