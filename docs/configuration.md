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
- **protect** lists paths or globs of actual verification definitions/settings (linter rules, formatter settings, suppression files). They are part of every Intent's approved baseline, so a Build cannot pass a check by weakening them. Dependency manifests and lockfiles are editable inputs when they only declare dependencies/project metadata: for example ordinary `mix.exs`, `package.json`, nested `go.mod`, `mix.lock`, `package-lock.json`, `npm-shrinkwrap.json` and `go.sum` are not protected merely because setup, format, compile, tests, vet, audit or another check consumes them. `cli/go.mod` is an editable input. A combined manifest is eligible when it embeds verification settings (such as eslintConfig) or itself defines a configured executable check, such as a package.json script used by an npm check or a Mix alias invoked by a configured command; that manifest remains whole-file protected. There is no field-level or dependency-only exception to explicit whole-file protection. Init rejects dependency-only protection with a path-specific correction request rather than silently deleting it. Existing committed configuration remains authoritative and is not migrated automatically.
- A genuine shaping conflict means a required edit cannot be avoided without changing the requested outcome and a currently protected path is involved. Shaping reports the protected path and reason without writing a ready Intent or starting approval/Build. Revise the request, or review and commit `.kogen/project.yaml` outside Build, then shape again while preserving checks and actual check configuration. That manual review changes the approval baseline; it is not approval of a protected edit. There is no protected-edit override. If a combined manifest is explicitly protected, revising the request is the available Build path.
- **Models** and efforts live only here; no command takes model flags. Defaults are Sol 6.1 high for shaping/review and Sol 6.1 medium for building. There is no separate planner; an older `models.plan` entry is ignored.

Init detects Go at the root or under `cli/`; other layouts can be supplied from the README. It deduplicates identical check commands; different commands remain because test paths and filters can change coverage. Machine bootstrap (`mix local.hex`, `mix local.rebar`) belongs in prerequisites rather than recurring setup.

Progress goes to stderr: each build/review request names its model/effort, and completed shape/build/review responses report usage and wall time. Probe completion reports exit status, timeout and duration without echoing its output. A quiet in-flight request has no streaming activity indicator; these notices do not imply a deadline or add retries. Build request durations are also stored as `wall_ms` in the existing run log.

`kogen intent refine <slug> <full-sha256> <file|->` corrects only an unapproved ready draft. It uses the shaping model and existing commands in a scratch checkout, merges only changed existing owned files, and requires normal approval afterward. It cannot edit configured protection, config, other Intents or shared/tracked step files, add/delete files, change Acceptance paths or add/remove a model. Original and candidate artifacts plus failure diagnostics remain in `.kogen/local/refinements/`; a changed checkout/hash/HEAD refuses publication.
