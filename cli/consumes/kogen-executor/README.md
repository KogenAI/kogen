# kogen-executor consumes suite

This package is kogen's side of the two-sided contract with kogen-executor. It pins exactly what kogen's own non-test code relies on from `github.com/KogenAI/kogen-executor/executor` and `.../executor/claudecode`, and nothing kogen does not use. kogen-executor's `contract/` suite states what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-executor/...)
```

## What it pins

kogen's call sites are `cli/engine.go` (`externalExecutor`), `cli/main.go` (`executorHook`), `cli/native.go` (the `claude-code runtime:` line, `exitFor`, uninstall) and `cli/readiness/readiness.go` (`checkClaude`).

- `TestFailIsAnExecutorSysError` (`executor_test.go`): `executor.Fail(executor.ReasonUnavailable, detail)` is a `*sys.Error` of class `executor`, reason `unavailable`, exit 1, rendered as `executor/unavailable: <detail>`, which `exitFor` prints.
- `TestNewReturnsAnExecutor`: `claudecode.New(claudecode.Options{Home, HookCommand, Token})` returns a non-nil `executor.Executor`, an interface with the methods `Describe` and `Start`; `Options.Home` and `Options.Token` are strings and `Options.HookCommand` is a `[]string`.
- `TestRuntimeLayout` (`runtime_test.go`): `claudecode.Root(home)` is `<home>/.kogen/claude-code`, `claudecode.RuntimeDir(home)` is `<Root>/<Version>`, `claudecode.RuntimePath(home)` is `<RuntimeDir>/claude`, and `claudecode.Version` is a dotted version.
- `TestSupportedAndUnsupportedMessage`: `claudecode.Supported` is ok exactly on macOS on Apple Silicon and Linux x86-64 (an assertion that holds on every platform, so nothing is skipped), and `claudecode.UnsupportedMessage("windows", "amd64")` is the refusal `Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64`.
- `TestPinnedAndNotPinnedMessage`: `claudecode.Pinned` accepts an answer whose first field is the pinned version and refuses any other, and `claudecode.NotPinnedMessage(path, answer)` is `Kogen's Claude Code at <path> reports <answer>, not the pinned <Version>`.
- `TestProbeRunsTheInstalledRuntime` and `TestProbeInstallsNothing`: `claudecode.Probe(ctx, home, args...)` runs the runtime at `RuntimePath(home)` with `--version` and `auth status --json` (the answer kogen parses for `loggedIn` and `authMethod`) and installs nothing: a missing runtime is a `*sys.Error` `executor/unavailable` whose text kogen shows as the answer, and no file appears under `Root(home)`.
- `TestHookSubcommand` and `TestHookDenyAndAllow` (`hook_test.go`): `claudecode.HookSubcommand` is `__kogen_executor_hook`; `claudecode.RunHook(args, stdin, stdout, stderr)` returns the exit code kogen exits with: a `pretool` write of a protected path prints exactly one line of PreToolUse deny JSON (`hookSpecificOutput` with `hookEventName` `PreToolUse`, `permissionDecision` `deny` and a reason naming the protected path) and exits 0; an unprotected path prints nothing and exits 0.
- `TestHookFailuresExitTwo`: an unreadable policy, no arguments, a missing policy file and an unknown mode exit 2 with nothing on stdout.

## Isolation

- `TestMain` removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic and live under `t.TempDir()`: homes that hold a fake `claude` shell script at `RuntimePath(home)`, and hook policy files with a checkout directory. No real Claude Code is installed, downloaded or run and no model is asked.
- No network is used, no port is opened, and the suite uses no real user HOME or host path.
- The suite imports only the standard library, `executor`, `claudecode` and kogen-loop `sys` (to inspect the `*sys.Error` values). It imports no `kogen/...` package, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness`, `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does. Each identifier is mapped to its tests in the Inventory below; the suite references every one and no other identifier of `executor` or `claudecode`.

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `claudecode.HookSubcommand` | `cli/main.go` | `TestHookSubcommand`, `TestNewReturnsAnExecutor` |
| `claudecode.New` | `cli/engine.go` | `TestNewReturnsAnExecutor` |
| `claudecode.NotPinnedMessage` | `cli/readiness/readiness.go` | `TestPinnedAndNotPinnedMessage`, `TestProbeRunsTheInstalledRuntime` |
| `claudecode.Options` | `cli/engine.go` | `TestNewReturnsAnExecutor` |
| `claudecode.Options.Home` | `cli/engine.go` | `TestNewReturnsAnExecutor` |
| `claudecode.Options.HookCommand` | `cli/engine.go` | `TestNewReturnsAnExecutor` |
| `claudecode.Options.Token` | `cli/engine.go` | `TestNewReturnsAnExecutor` |
| `claudecode.Pinned` | `cli/readiness/readiness.go` | `TestPinnedAndNotPinnedMessage`, `TestProbeRunsTheInstalledRuntime` |
| `claudecode.Probe` | `cli/readiness/readiness.go` | `TestProbeRunsTheInstalledRuntime`, `TestProbeInstallsNothing` |
| `claudecode.Root` | `cli/native.go` | `TestRuntimeLayout`, `TestProbeInstallsNothing` |
| `claudecode.RunHook` | `cli/main.go` | `TestHookDenyAndAllow`, `TestHookFailuresExitTwo` |
| `claudecode.RuntimeDir` | `cli/readiness/readiness.go` | `TestRuntimeLayout` |
| `claudecode.RuntimePath` | `cli/native.go`, `cli/readiness/readiness.go` | `TestRuntimeLayout`, `TestProbeRunsTheInstalledRuntime` |
| `claudecode.Supported` | `cli/readiness/readiness.go` | `TestSupportedAndUnsupportedMessage` |
| `claudecode.UnsupportedMessage` | `cli/readiness/readiness.go` | `TestSupportedAndUnsupportedMessage` |
| `claudecode.Version` | `cli/native.go` | `TestRuntimeLayout`, `TestPinnedAndNotPinnedMessage`, `TestProbeRunsTheInstalledRuntime` |
| `executor.Executor` | `cli/engine.go` | `TestNewReturnsAnExecutor` |
| `executor.Fail` | `cli/engine.go` | `TestFailIsAnExecutorSysError` |
| `executor.ReasonUnavailable` | `cli/engine.go` | `TestFailIsAnExecutorSysError`, `TestProbeInstallsNothing` |
