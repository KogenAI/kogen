# External projects

Kogen keeps its workflow engine and resources in the Kogen checkout. Each
target Git checkout owns `.kogen/project.yaml`, which declares its setup hint,
required dependencies, and verification commands. The Rust `kogen` command
selects the target; the engine reads this file and owns workflow state.

## Project configuration

Create `.kogen/project.yaml` in the target repository and commit it with the
project baseline:

```yaml
setup:
  argv: [mise, install]
  requires:
    - executable: mise
    - path: package.json
checks:
  - name: unit
    argv: [npm, test]
  - name: lint
    argv: [npm, run, lint]
```

`checks` is a nonempty ordered list. Every check has a unique `name` and an
`argv` list whose first item names the executable; Kogen resolves that
executable through `PATH` or as a project-relative path before dispatch.
`setup` is optional. When present, it has an `argv` list and a `requires` list
of `{executable: NAME}` or `{path: PATH}` entries. Relative prerequisite paths
stay inside the target checkout. Absolute prerequisite paths may name machine
dependencies.

Configuration contains argument arrays, not shell command strings. Kogen
checks prerequisites and reports the configured setup command when one is
missing. It never runs setup or fetches dependencies automatically. Project
checks are resolved into JSON-safe argv records; the raw configuration and
resolved command set each receive a SHA-256 for an admitted run to freeze.

### Project-owned checks

When `.kogen/project.yaml` exists, its ordered `checks` list supplies the
project's verification targets. Each name must be a safe lowercase target
name and each check is a nonpaid project command with no inferred
dependencies. The frozen verification catalog records the exact project.yaml
bytes, their digest, and the digest of resolved commands; project catalogs do
not claim engine test-surface integrity. A project with a missing declared
setup prerequisite or unavailable check executable is refused before a check
can be dispatched.

The verification plan resolves each frozen command for the Candidate. If its
executable came from inside the control checkout, the same relative path must
exist as an executable in the Candidate; a symlink that escapes the Candidate
is refused. Executables resolved outside the project, such as a tool found on
PATH, remain external tools. Runner callers pass the resolved argv directly,
and the child still runs under process custody with the usual scrubbed
environment, timeout, log, and exit-status receipt.

The project configuration remains the source of command names and arguments.
No command is dispatched until a controller invokes the runner with the
frozen argv. Legacy engine fixtures without `.kogen/project.yaml` continue to
use the verification-target catalog and Makefile inventory.

Every command runs against the explicitly selected Git root. Build admission
requires a committed HEAD on any attached branch in a clean primary worktree.
Linked worktrees are refused. Shape may inspect dirty, detached or linked
checkouts because it does not publish a Build.
The project identity is lowercase SHA-256 of the canonical Git root, so a
symlinked spelling of one checkout keeps the same identity.

## Engine resources

Prompts and other Kogen resources resolve from the loaded engine checkout,
independent of the target and caller working directory. Resource paths are
relative to that checkout and reject traversal or symlinks that resolve
outside it. For example, an engine-owned prompt is addressed as
`priv/kogen/prompts/developer.md`; a same-named target file is never a
fallback.

The project may be Kogen itself for an explicitly selected self-development
flow. External-project command wiring should keep target and engine identities
visible in the frozen admission record.
