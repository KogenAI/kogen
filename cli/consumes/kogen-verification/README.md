# kogen-verification consumes suite

This package is kogen's side of the two-sided contract with kogen-verification. It pins exactly what kogen's own non-test code relies on from `github.com/KogenAI/kogen-verification/verify`, and nothing kogen does not use. kogen-verification's `contract/` suite states what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-verification/...)
```

## What it pins

kogen resolves the installed tools once per command: `verify.ToolsFromInstall(job.root)` in `cli/engine.go` and `cli/readiness.go`. It hands the result to the other producers (`InitInput.Tools`, `ShapeInput.Tools`, `Deps.Tools`, ...) and `cli/readiness/readiness.go` reads its three fields to set `KOGEN_NODE`, `KOGEN_QUINT` and `KOGEN_CUCUMBER` for the bundled-tool checks.

- `tools_test.go`: `verify.ToolsFromInstall` is `func(string) verify.Tools`; `verify.Tools` has the string fields `Node`, `Quint` and `Cucumber` (`TestToolsFields`).
- `TestToolsFromInstallNamesTheNodeOfTheInstall`: `Node` is the path the install root's `node-path` file names, without its trailing line ending.
- `TestToolsFromInstallWithoutNodePathFile`: without a readable `node-path`, `Node` is empty (no other node runs).
- `TestToolsFromInstallLocatesQuintAndCucumberUnderLib`: `Quint` is `<root>/lib/quint/node_modules/@informalsystems/quint/dist/src/cli.js` and `Cucumber` is `<root>/lib/cucumber/node_modules`, the same paths `cli/main.go` exports as `KOGEN_QUINT` and `KOGEN_CUCUMBER`.

## Isolation

- `TestMain` removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic install roots under `t.TempDir()`. Nothing runs and nothing reaches the network.
- The suite imports only the standard library and `verify`, imports no `kogen/...` package, uses no fixed port and no host path, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness`, `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does. Each identifier is mapped to its tests in the Inventory below; the suite references every one and no other identifier of `verify`.

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `verify.Tools` | `cli/engine.go`, `cli/readiness/readiness.go` | `TestToolsFields` |
| `verify.Tools.Cucumber` | `cli/readiness/readiness.go` | `TestToolsFields`, `TestToolsFromInstallLocatesQuintAndCucumberUnderLib` |
| `verify.Tools.Node` | `cli/readiness/readiness.go` | `TestToolsFields`, `TestToolsFromInstallNamesTheNodeOfTheInstall`, `TestToolsFromInstallWithoutNodePathFile` |
| `verify.Tools.Quint` | `cli/readiness/readiness.go` | `TestToolsFields`, `TestToolsFromInstallLocatesQuintAndCucumberUnderLib` |
| `verify.ToolsFromInstall` | `cli/engine.go`, `cli/readiness.go` | the signature pin in `tools_test.go`, `TestToolsFromInstall...` |
