# Tiny Tasks

Tiny Tasks is a local, plain-Elixir task list used to exercise Kogen's REL-1
real-use journey. It has no database, Hex dependencies, services, or network
access at runtime. Its requested next feature is recorded in
[FEATURE-REQUEST.md](FEATURE-REQUEST.md).

## Start here

Run the existing CLI from this directory:

```sh
mix todo.add "Call the dentist"
mix todo.add "Pick up a parcel"
mix todo.list
```

Tasks live at `~/.tiny_tasks/tasks.tsv` by default. Set `TODO_FILE` to use a
different file. The file is local data, not a project artifact.

## Check it

```sh
mix format --check-formatted
mix test --warnings-as-errors
npm ci
npm test
```

The Mix checks cover the Elixir app. The pinned Cucumber bridge feature runs the
real Mix CLI and verifies its output. The live project's configured acceptance
command runs the shaped feature with that same step bridge.

## Conventions

- Keep the app plain Elixir and dependency-free; Cucumber is the only Node
  development dependency.
- Store each task's stable numeric ID, status, and title in the local task file.
- Exercise CLI behavior through real Mix commands and real temporary files.
- The live request and its independent acceptance qualification are linked from
  [FEATURE-REQUEST.md](FEATURE-REQUEST.md) and
  [the qualification folder](../tiny_tasks-qualification/README.md).

## Testing policy

Choose tests from the requested behavior, not from the number of functions or
modules. Test command-line behavior through the CLI and file behavior with real
temporary files and processes. Assert outputs, observable effects, and
contractual state; do not assert private helpers, call order, or module layout.
Name cases after the request clause they cover. Add cases only for conditions,
outcomes, boundaries, or state transitions in the contract. Do not add a
production abstraction only to make it mockable.

## Folder map

| Path | Purpose |
| --- | --- |
| `FEATURE-REQUEST.md` | The one feature request used by REL-1 |
| `lib/` | Task storage and Mix CLI commands |
| `test/` | ExUnit coverage of the existing CLI behavior |
| `features/bridge.feature` | Smoke acceptance feature for the step bridge |
| `features/steps/` | Cucumber steps that invoke the real Mix CLI |
| `../tiny_tasks-qualification/` | Wrong and correct implementations used to qualify the acceptance check |
