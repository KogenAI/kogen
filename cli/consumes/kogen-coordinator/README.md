# kogen-coordinator consumes suite

This package is kogen's side of the two-sided contract with kogen-coordinator. It pins exactly what kogen's own non-test code relies on from `github.com/KogenAI/kogen-coordinator/git` and `github.com/KogenAI/kogen-coordinator/project`, and nothing kogen does not use. kogen-coordinator's `contract/` suite states what the producer provides; this suite states what kogen consumes, so a producer's change can be checked against it without building and testing kogen in full.

Run it with the rest of the module, or alone:

```sh
(cd cli && go test -race -count=1 ./consumes/kogen-coordinator/...)
```

## What it pins

kogen's call sites are `cli/readiness/readiness.go` (the report that ends `kogen init`: `checkGit`, `checkConfig`, `checkModels`) and `cli/facts.go` (the Build lock owner behind `kogen context`).

- `git_test.go`: `git.OpenReadOnly` is `func(string, []string) (*git.Repo, error)`, finds the work tree root (`Repo.Dir`) from the root and from a folder inside it, and refuses a directory that is no repository; `Repo.CanCommit` is `func(*git.Repo) bool`, true with a Git `user.name` and `user.email` and false when either is missing.
- `lock_test.go`: `git.LockOwner` is `func(string) (string, string, bool)`. An absent lock gives no pid, no token and not held; a lock file of the current Kogen (`kogen-build-lock 1`, `pid <pid>`, `token <token>`) gives its pid and token, held only while a process has the kernel lock on it; a plain pid file of an earlier Kogen gives its pid, no token and not held for a process that is not running.
- `config_test.go`:
  - `project.ConfigPath` is `.kogen/project.yaml`; `project.ModelRoles` is `shape`, `build`, `review` in that order.
  - `project.ParseConfig` is `func(string, string) (*project.Config, error)`; `project.Config.Models` has a `project.Role` for every model role, also when the file names none (native, no provider); `project.Role.Provider` is the file's provider; `project.Role.Executor` is `project.ExecutorClaudeCode` for `executor: claude-code`, which makes `project.Role.External` true, and empty for native roles.
  - `project.Config.ShapeWorkers` is a `project.Workers`: `project.Workers.Enabled` and `project.Workers.Roles` keyed `read`, `probe` and `draft`, with a role the file does not give absent from the map; disabled when the section is missing or `enabled: false`.
  - An invalid file gives a `*sys.Error` whose `Detail` is the file name, whose `Lines` (one per problem, `line <n>: ...`, which readiness shows and turns into the lines to edit) and whose `Exit` is 3; the configuration of an earlier Kogen gives a `Detail` and no `Lines`.
  - `project.ReadableConfig` is `func(string) *project.Config`: it keeps the roles and workers it could read of an invalid file and gives a native role for every model role and no workers for text it cannot read or for no text.

## Isolation

- `TestMain` removes every inherited `GIT_*` and `KOGEN_*` variable, gives the process a HOME of its own and sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- The fixtures are synthetic and live under `t.TempDir()`: a Git repository with its own identity, no signing and an empty hooks folder, lock files written by the test, and configuration text. Git runs with `GIT_CEILING_DIRECTORIES` set to the fixture's own directory.
- No model, sign-in or network traffic is involved: the suite starts no server and uses no port.
- The suite imports only the standard library, kogen-coordinator `git` and `project`, and kogen-loop `sys` (the `*sys.Error` that `ParseConfig` returns). It imports no `kogen/...` package, uses no host path, has no `t.Skip`, no sleep and no build constraint, and passes with `-count=1`, `-trimpath` and `-race`.

## How coverage was checked

The identifiers kogen's non-test code uses from this dependency were listed by type-checking kogen's non-test packages (`kogen`, `kogen/readiness`, `kogen/internal/testrelease`) with go/types (`Uses` and `Selections`), as the inventory helper in `features/steps/k-consumes-kogen__inventory.js` does. Each identifier is mapped to its tests in the Inventory below; the suite references every one and no other identifier of `git` or `project` except the named types of their signatures (`project.Workers`).

## Inventory

| Interface | Consumer call site | Covering tests |
| --- | --- | --- |
| `git.LockOwner` | `cli/facts.go` | the signature pin in `lock_test.go`, `TestLockOwnerReadsTheDiagnosticsAndWhetherARunningProcessHoldsIt`, `TestLockOwnerReadsALockOfAnEarlierKogen` |
| `git.OpenReadOnly` | `cli/readiness/readiness.go` | the signature pin in `git_test.go`, `TestOpenReadOnlyFindsTheWorkTreeRoot`, `TestOpenReadOnlyRefusesADirectoryThatIsNoRepository` |
| `git.Repo` | `cli/readiness/readiness.go` | `TestOpenReadOnlyFindsTheWorkTreeRoot`, `TestCanCommitNeedsAUserNameAndEmail` |
| `git.Repo.CanCommit` | `cli/readiness/readiness.go` | the method pin in `git_test.go`, `TestCanCommitNeedsAUserNameAndEmail` |
| `git.Repo.Dir` | `cli/readiness/readiness.go` | `TestOpenReadOnlyFindsTheWorkTreeRoot` |
| `project.Config` | `cli/readiness/readiness.go` | the signature pins in `config_test.go`, `TestParsedConfigHasARoleForEveryModelRole` |
| `project.Config.Models` | `cli/readiness/readiness.go` | `TestParsedConfigHasARoleForEveryModelRole`, `TestRoleProviderAndExecutor`, `TestReadableConfigKeepsWhatItCanRead` |
| `project.Config.ShapeWorkers` | `cli/readiness/readiness.go` | `TestShapeWorkers`, `TestParsedConfigHasARoleForEveryModelRole`, `TestReadableConfigKeepsWhatItCanRead` |
| `project.ConfigPath` | `cli/readiness/readiness.go` | `TestConfigPathAndModelRoles` |
| `project.ExecutorClaudeCode` | `cli/engine.go` | `TestRoleProviderAndExecutor` |
| `project.ModelRoles` | `cli/readiness/readiness.go` | `TestConfigPathAndModelRoles`, `TestParsedConfigHasARoleForEveryModelRole`, `TestReadableConfigKeepsWhatItCanRead` |
| `project.ParseConfig` | `cli/readiness/readiness.go` | the signature pin in `config_test.go`, `TestParseConfigRefusalsAreSysErrorsWithLines`, `TestParseConfigOldKogenFolderHasNoLines`, every other config test |
| `project.ReadableConfig` | `cli/readiness/readiness.go` | the signature pin in `config_test.go`, `TestReadableConfigKeepsWhatItCanRead` |
| `project.Role` | `cli/readiness/readiness.go`, `cli/engine.go` | `TestRoleProviderAndExecutor`, `TestShapeWorkers` |
| `project.Role.Executor` | `cli/engine.go` | `TestRoleProviderAndExecutor` |
| `project.Role.External` | `cli/readiness/readiness.go` | the method pin in `config_test.go`, `TestRoleProviderAndExecutor`, `TestShapeWorkers` |
| `project.Role.Provider` | `cli/readiness/readiness.go` | `TestRoleProviderAndExecutor`, `TestShapeWorkers`, `TestReadableConfigKeepsWhatItCanRead` |
| `project.Workers.Enabled` | `cli/readiness/readiness.go` | `TestShapeWorkers`, `TestParsedConfigHasARoleForEveryModelRole` |
| `project.Workers.Roles` | `cli/readiness/readiness.go` | `TestShapeWorkers`, `TestReadableConfigKeepsWhatItCanRead` |
