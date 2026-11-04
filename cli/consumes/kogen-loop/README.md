# kogen-loop consumes suite

This package is kogen's side of the two-sided contract with kogen-loop, the in-tree copy under `cli/third_party/kogen-loop` that kogen's `go.mod` replaces as `kogen-loop`. It pins exactly what kogen's own non-test code relies on from the packages `kogen-loop/provider` and `kogen-loop/sys`, and nothing kogen does not use. kogen-loop's own suites state what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-loop/...)
```

## What it pins

The call sites are `cli/engine.go` (the session of every command: `sys.New`, `Debug`, `WatchSignals`, `Err`, `Groups`, `sys.Terminate`), `cli/main.go` (`sys.MaybeSupervise`, `sys.EnableSupervisor`, `sys.Fail` and its exit codes), `cli/native.go` (the provider list, `provider login`, `exitFor`), `cli/readiness.go` and `cli/readiness/readiness.go` (the readiness report: `Session.Run`, `RequireLogin`, `Lookup`, the configuration error's `Detail` and `Lines`) and `cli/facts.go` (`sys.New`, `WatchSignals`).

- `sys_session_test.go`: the signatures kogen calls; `sys.New` takes the process's environment and working directory; `Getenv` reads the session's `Env` (the last setting of a name wins); `Out` writes text unchanged and `Puts` a line, to the standard output the process had when the session was made; `Stderr` is a replaceable writer; `Debug` writes `[debug] ` lines only with `KOGEN_LOG_LEVEL=debug` in the session's environment.
- `sys_error_test.go`: `sys.Fail` makes an error with its `Detail` and `Exit`; `Render` is `class/reason: detail` and the `Lines` indented by two spaces, each ending in a newline; `sys.AsError` finds the error in a wrapped chain and reports none for other errors; `WatchSignals` turns a real SIGINT, SIGTERM or SIGHUP, sent to the test process after the watch began, into a cancelled `Context` and an `*sys.Interrupted` from `Err` whose `ExitCode` is 130, 143 or 129.
- `sys_run_test.go`: `Run` runs `/bin/sh -c` in the given directory and returns the exit status (128 plus the signal for a killed command, 127 for an unknown one); `Options.Env` adds variables to the session's environment; commands run under the supervisor (the shell's parent is a supervisor that leads the group `Groups` names) once `sys.EnableSupervisor` was called and `sys.MaybeSupervise` ran first, and `MaybeSupervise` ignores every other command line; a command's background process outlives `Run` unless `Options.KillGroupOnExit`, and `sys.Terminate(Groups())` stops it and returns only when the group is empty; after an interrupt `Run` starts nothing and returns `*sys.Interrupted`, also for a command that is running.
- `provider_catalog_test.go`: `Lookup` finds chatgpt, supergrok, opencode-go, anthropic and openai-compatible by name (`Info.Name`), `""` as chatgpt, and reports an unknown name; the JSON of `Profiles` has a schema version and profiles with the keys `kogen provider list --json` publishes; `OfficialText` has the heading, one line per profile and the closing notes; `Status` lists one `name: state` line per provider in catalog order (openai-compatible once a key is saved, the Claude Code token last) and says when a saved login cannot be used; `ClaudeCodeToken` is the saved token or none; `RequireLogin` refuses with `provider/login`, exit 4, and the command that fixes it, checking only the providers of the given `Role`s.
- `provider_login_test.go`: `CheckSeams` accepts unset and loopback `KOGEN_PROVIDER_URL` and `KOGEN_AUTH_URL` and refuses anything else with `environment/invalid_test_seam`, exit 3; `NewClient` has no `Input` (standard input) and `Input` can be replaced; `StdinInput` reads the process's standard input and its `Reader` can be replaced; `Login` saves a key read from `Input.Reader` privately (file 0600, directories 0700, nothing printed of the key), refuses an unknown provider, an empty key and an invalid Claude Code token with `provider/login_failed` (`provider/login` for Anthropic), exit 4; `LoginWithBaseURL` binds an openai-compatible key to the origin of an HTTPS base URL and refuses an http, missing or invalid URL, as does `Login` without one; `Login` of chatgpt prints the authorization address, passes it to the `RedirectFunc`, ignores a redirect with the wrong state, exchanges the code with the PKCE verifier at a loopback authorization server, saves the login, reports provider errors with exit 4 and stops with `*sys.Interrupted` when the caller interrupts.

Not pinned, because kogen does not use it: the output of a command (`Result.Output`), the other fields of `sys.Error` and the other providers' sign-in flows (SuperGrok's device flow is not exercised).

## Isolation

- `TestMain` first runs `sys.MaybeSupervise` and `sys.EnableSupervisor` like kogen's main, removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic and live under `t.TempDir()`: a HOME of the test's own, a working directory, the credential files the sign-ins write, and the files the tested shell commands write. A session's standard output is a file of the fixture's own.
- The only server is a loopback `httptest` server on a free port that plays the ChatGPT token endpoint, reached through `KOGEN_AUTH_URL` in the session's environment. Nothing reaches the network and no model runs.
- The signal tests send a signal to the test process only after `WatchSignals` caught it and wait for the session's context before stopping the watch; they do not run in parallel.
- The suite imports only the standard library and `kogen-loop/provider` and `kogen-loop/sys`. It imports no `kogen/...` package, uses no fixed port and no host path, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness`, `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does: 48 identifiers, 18 of `provider` and 30 of `sys`. Each is mapped to its tests in the Inventory below; the suite references every one and no other identifier of `provider` or `sys` except the named types in their signatures (`provider.Info`, `provider.Input`, `provider.ProfileCatalog`, `sys.Error`, `sys.Session`, `sys.Options`, `sys.Result`).

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `provider.CheckSeams` | `cli/native.go` | `TestCheckSeamsAcceptsOnlyLoopbackTestURLs`, `TestLoginRefusesAnInvalidSeamBeforeAnythingHappens` |
| `provider.ClaudeCodeToken` | `cli/native.go`, `cli/readiness/readiness.go` | `TestClaudeCodeTokenIsTheSavedTokenOrNone`, `TestLoginSavesAKeyReadFromTheInput`, `TestStatusListsTheLocalLoginsInCatalogOrder` |
| `provider.Client` | `cli/engine.go`, `cli/native.go` | `TestNewClientKeepsTheVersionAndReadsKeysFromStandardInput`, every `TestLogin...` |
| `provider.Client.Input` | `cli/native.go` | `TestNewClientKeepsTheVersionAndReadsKeysFromStandardInput`, `TestStdinInputReadsTheProcessStandardInput`, `TestLoginSavesAKeyReadFromTheInput` |
| `provider.Client.Login` | `cli/native.go` | `TestLoginSavesAKeyReadFromTheInput`, `TestLoginRefusalsAreProviderErrorsWithExit4`, `TestLoginRefusesAnInvalidSeamBeforeAnythingHappens`, `TestLoginSignsInToChatGPTThroughTheRedirectFunc`, `TestLoginToChatGPTFailsWithProviderErrors`, `TestLoginToChatGPTStopsOnAnInterrupt` |
| `provider.Client.LoginWithBaseURL` | `cli/native.go` | `TestLoginWithBaseURLBindsAnOpenAICompatibleKeyToItsOrigin` |
| `provider.Info.Name` | `cli/readiness/readiness.go` | `TestLookupFindsTheProvidersKogenKnows` |
| `provider.Input.Reader` | `cli/native.go` | `TestStdinInputReadsTheProcessStandardInput`, `TestLoginSavesAKeyReadFromTheInput` |
| `provider.Lookup` | `cli/readiness/readiness.go` | `TestLookupFindsTheProvidersKogenKnows` |
| `provider.NewClient` | `cli/engine.go`, `cli/native.go` | `TestNewClientKeepsTheVersionAndReadsKeysFromStandardInput`, every `TestLogin...` |
| `provider.OfficialText` | `cli/native.go` | `TestOfficialTextIsTheCompatibilityTextOfTheProviderList` |
| `provider.Profiles` | `cli/native.go` | `TestProfilesIsTheOfflineCatalogKogenPrintsAsJSON`, `TestOfficialTextIsTheCompatibilityTextOfTheProviderList` |
| `provider.RedirectFunc` | `cli/native.go` | `TestLoginSignsInToChatGPTThroughTheRedirectFunc`, `TestLoginToChatGPTFailsWithProviderErrors`, `TestLoginToChatGPTStopsOnAnInterrupt` |
| `provider.RequireLogin` | `cli/readiness/readiness.go` | `TestRequireLoginRefusesARoleWithoutAStoredLogin`, `TestLoginSavesAKeyReadFromTheInput` |
| `provider.Role` | `cli/readiness/readiness.go` | `TestRequireLoginRefusesARoleWithoutAStoredLogin` |
| `provider.Role.Provider` | `cli/readiness/readiness.go` | `TestRequireLoginRefusesARoleWithoutAStoredLogin` |
| `provider.Status` | `cli/native.go` | `TestStatusListsTheLocalLoginsInCatalogOrder`, `TestStatusSaysWhenASavedLoginCannotBeUsed` |
| `provider.StdinInput` | `cli/native.go` | `TestStdinInputReadsTheProcessStandardInput` |
| `sys.AsError` | `cli/native.go`, `cli/readiness/readiness.go` | `TestAsErrorFindsTheErrorInAChain`, every refusal test (`wantFailure`) |
| `sys.EnableSupervisor` | `cli/main.go` | `TestRunStartsCommandsUnderTheSupervisor` (enabled in `TestMain`) |
| `sys.Error.Detail` | `cli/readiness/readiness.go` | `TestFailIsAnErrorWithItsExitAndDetail`, `TestRenderPrintsTheDetailLinesIndented` |
| `sys.Error.Exit` | `cli/native.go` | `TestFailIsAnErrorWithItsExitAndDetail`, `TestRenderPrintsTheDetailLinesIndented`, every refusal test (`wantFailure`) |
| `sys.Error.Lines` | `cli/readiness/readiness.go` | `TestRenderPrintsTheDetailLinesIndented` |
| `sys.Error.Render` | `cli/native.go` | `TestFailIsAnErrorWithItsExitAndDetail`, `TestRenderPrintsTheDetailLinesIndented`, every refusal test (`wantFailure`) |
| `sys.Fail` | `cli/main.go`, `cli/native.go` | `TestFailIsAnErrorWithItsExitAndDetail`, `TestRenderPrintsTheDetailLinesIndented`, `TestAsErrorFindsTheErrorInAChain` |
| `sys.Interrupted` | `cli/native.go` | `TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt`, `TestRunAfterAnInterruptStartsNothing`, `TestRunInterruptedWhileRunningReturnsTheInterruptAndTerminateStopsTheCommand`, `TestLoginToChatGPTStopsOnAnInterrupt` |
| `sys.Interrupted.ExitCode` | `cli/native.go` | `TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt`, `TestRunAfterAnInterruptStartsNothing` |
| `sys.MaybeSupervise` | `cli/main.go` | `TestMaybeSuperviseIgnoresOtherCommandLines`, `TestRunStartsCommandsUnderTheSupervisor` (called first in `TestMain`) |
| `sys.New` | `cli/engine.go`, `cli/native.go`, `cli/facts.go` | `TestNewTakesTheProcessEnvironmentAndDirectory`, every fixture |
| `sys.Options` | `cli/readiness/readiness.go` | `TestRunOptionsEnvAddsToTheCallersEnvironment`, `TestRunOptionsKillGroupOnExitStopsTheCommandsGroup` |
| `sys.Options.Env` | `cli/readiness/readiness.go` | `TestRunOptionsEnvAddsToTheCallersEnvironment` |
| `sys.Options.KillGroupOnExit` | `cli/readiness/readiness.go` | `TestRunOptionsKillGroupOnExitStopsTheCommandsGroup` |
| `sys.Result` | `cli/readiness/readiness.go` | `TestRunReturnsTheExitStatus` |
| `sys.Result.Status` | `cli/readiness/readiness.go` | `TestRunReturnsTheExitStatus`, `TestRunOptionsKillGroupOnExitStopsTheCommandsGroup` |
| `sys.Session` | `cli/engine.go`, `cli/native.go`, `cli/readiness.go` | `TestNewTakesTheProcessEnvironmentAndDirectory`, the method pins in `sys_session_test.go` |
| `sys.Session.Context` | `cli/engine.go`, `cli/native.go` | `TestNewTakesTheProcessEnvironmentAndDirectory`, `TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt` |
| `sys.Session.Cwd` | `cli/engine.go`, `cli/readiness/readiness.go` | `TestNewTakesTheProcessEnvironmentAndDirectory` |
| `sys.Session.Debug` | `cli/engine.go` | `TestDebugWritesOnlyWhenTheCallerAsksForDebugLogging` |
| `sys.Session.Env` | `cli/readiness/readiness.go` | `TestNewTakesTheProcessEnvironmentAndDirectory`, `TestGetenvReadsTheSessionsEnvironment` |
| `sys.Session.Err` | `cli/engine.go` | `TestNewTakesTheProcessEnvironmentAndDirectory`, `TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt` |
| `sys.Session.Getenv` | `cli/native.go` | `TestGetenvReadsTheSessionsEnvironment`, `TestNewTakesTheProcessEnvironmentAndDirectory` |
| `sys.Session.Groups` | `cli/engine.go` | `TestRunStartsCommandsUnderTheSupervisor`, `TestGroupsAndTerminateStopWhatACommandLeftBehind` |
| `sys.Session.Out` | `cli/readiness.go` | `TestOutAndPutsWriteToStandardOutput` |
| `sys.Session.Puts` | `cli/native.go` | `TestOutAndPutsWriteToStandardOutput` |
| `sys.Session.Run` | `cli/readiness/readiness.go` | `TestRunReturnsTheExitStatus`, `TestRunOptionsEnvAddsToTheCallersEnvironment`, `TestRunAfterAnInterruptStartsNothing`, `TestRunInterruptedWhileRunningReturnsTheInterruptAndTerminateStopsTheCommand` |
| `sys.Session.Stderr` | `cli/native.go` | `TestStderrIsWhereKogenWritesNotices`, `TestDebugWritesOnlyWhenTheCallerAsksForDebugLogging` |
| `sys.Session.WatchSignals` | `cli/engine.go`, `cli/native.go` | `TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt`, `TestLoginToChatGPTStopsOnAnInterrupt` |
| `sys.Terminate` | `cli/engine.go` | `TestGroupsAndTerminateStopWhatACommandLeftBehind`, `TestRunInterruptedWhileRunningReturnsTheInterruptAndTerminateStopsTheCommand` |
