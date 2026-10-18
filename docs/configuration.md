# `.kogen/project.yaml`

`kogen init` writes this file and commits it: it finds the project's commands, runs each once on the committed tree and keeps only those that pass, and prints what it left out. Edit the file only where you disagree, then commit it. Every command reads it; an invalid file is refused with its line numbers.

```yaml
version: 1
commands:
  setup:                # run before readiness dry runs and before each Build, in order
    - 'mix deps.get'
  fix:                  # deterministic fixers, run once after each builder round
    - 'mix format'
  checks:               # the project's fast regression suite; a Build commits only when all pass
    - {name: format, run: 'mix format --check-formatted'}
    - {name: test, run: 'mix test'}
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: 'features/steps'   # where shaping writes step-definition files
protect: ['.formatter.exs']       # check configuration a Build must not change
models:
  shape:  {model: gpt-6.1-sol, effort: high}
  build:  {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
```

- **Commands** run with `/bin/sh -c` in the repository root, with your environment, stdin closed and no time limit. Kogen adds `KOGEN_NODE` and `KOGEN_CUCUMBER` (its own Node and Cucumber) and, for the acceptance command, `KOGEN_ACCEPTANCE_FEATURES` and `KOGEN_ACCEPTANCE_REPORT`.
- **Checks** are `{name, run}` with unique lowercase names (letters, digits, dashes); `acceptance` and `model` are reserved. A check that already fails on the unchanged tree stops a Build before it starts, so fix it or remove it.
- **Flaky tests.** A Build's repair loop treats a failing check as something to fix. If the project's tests fail now and then, rerun only the failed ones once in the same check, for example `mix test || mix test --failed`, or `npm test || npm test` for a runner without a failed-only mode.
- **Services.** Test databases and other services are the project's own: start them before Kogen, and put what prepares them (for example `mix ecto.create`) in `setup`. A check that needs a stopped service fails in `kogen init` and is left out; add it back once the service runs.
- **Acceptance.** Kogen ships Cucumber 13.3.0 and runs it on its own Node, so the project needs no Node of its own. A project that already has `@cucumber/cucumber` in its `package.json` keeps its own, run as `"$KOGEN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js ...`. Step files go in `steps_dir` and use `require('@cucumber/cucumber')`.
- **protect** lists paths or globs of check configuration (linter rules, formatter settings, suppression files). They are part of every Intent's approved baseline, so a Build cannot pass a check by weakening it.
- **Models** and efforts live only here; no command takes model flags. Defaults are Sol 6.1 high for shaping/review and Sol 6.1 medium for building. There is no separate planner; an older `models.plan` entry is ignored.
