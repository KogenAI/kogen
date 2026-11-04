# kogen-setup consumes suite

This package is kogen's side of the two-sided contract with kogen-setup. It pins exactly what kogen's own non-test code relies on from `github.com/KogenAI/kogen-setup/setup`, and nothing kogen does not use. kogen-setup's `contract/` suite states what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-setup/...)
```

## What it pins

kogen's call site is `cli/engine.go`: `setup.Init(s.Context(), s, setup.InitInput{Client: client, Tools: tools})`, with the exit code used only when the error is nil (kogen then prints the readiness report) and `exitFor` in `cli/native.go` mapping the error.

- `api_test.go`: `setup.Init` is `func(context.Context, *sys.Session, setup.InitInput) (int, error)`; `setup.InitInput` has the fields `Client` (`*provider.Client`) and `Tools` (`verify.Tools`).
- `TestInitUsesTheClientAndTheToolsOfTheInput`: the client asks the shaping model once, reading the login under the session's HOME (kogen sets no home), and the tools are the ones the project's setup runs with (the acceptance bridge writes `features/steps/README.md` and is committed).
- `TestInitSucceedsWithExitZero`: exit 0 and a nil error for the first commit of an empty repository ("Initial commit" with `.kogen/project.yaml`), a configured project ("Add Kogen configuration", `.gitignore` gains `.kogen/local/`) and a project that is already initialized (no new commit, no request).
- `TestInitRefusalsAreSysErrorsWithTheirExit`: refusals are `*sys.Error`s whose `Exit` is Init's exit and whose rendering starts with `class/reason: `, which `exitFor` prints: `environment/not_a_git_repo` 3, `environment/git_identity_missing` 3, `environment/no_commits` 3, `environment/dirty_tree` 5, `provider/login` 4, `provider/init_invalid` 4, `environment/commit_failed` 3. Nothing is committed.
- `TestInitInterruptsExitWithTheSignalsCode`: an interrupted session gives `*sys.Interrupted` with exit 130 (SIGINT), 143 (SIGTERM) or 129 (SIGHUP), also while the model request is in flight. Nothing is written.
- `TestInitInternalFailureIsExit70`: any other failure is exit 70 with an error that is neither a `*sys.Error` nor a `*sys.Interrupted`, which `exitFor` prints as `controller/internal_error`.

## Isolation

- `TestMain` removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic and live under `t.TempDir()`: a Git repository with its own identity, no signing and an empty hooks folder, fake `npm` and `node` programs, a HOME of the fixture's own with a fake ChatGPT login.
- The model is a loopback `httptest` server on a free port, reached through `KOGEN_PROVIDER_URL` in the session's environment, that plays scripted streamed answers. No real model runs and nothing reaches the network.
- The suite imports only the standard library, `setup`, kogen-verification `verify` and kogen-loop `provider` and `sys` (as fixtures: the client, the tools and the session). It imports no `kogen/...` package, uses no fixed port and no host path, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness`, `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does. Each identifier is mapped to its tests in the Inventory below; the suite references every one and no other identifier of `setup`.

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `setup.Init` | `cli/engine.go` | the signature pin in `api_test.go`, every `TestInit...` |
| `setup.InitInput` | `cli/engine.go` | `TestInitInputFields` |
| `setup.InitInput.Client` | `cli/engine.go` | `TestInitInputFields`, `TestInitUsesTheClientAndTheToolsOfTheInput` |
| `setup.InitInput.Tools` | `cli/engine.go` | `TestInitInputFields`, `TestInitUsesTheClientAndTheToolsOfTheInput` |
