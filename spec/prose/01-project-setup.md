# 01 Project setup

`kogen init` prepares a Git repository and configures it itself: it finds the project's setup, fixers and checks, keeps only the checks that pass on the committed tree, adds a minimal Cucumber bridge when the project has no acceptance runner, and commits the configuration in one commit. The user edits `.kogen/project.yaml` only to disagree.

**SET-1 — Repository.** `kogen init` works on the Git repository containing the current directory, at its root. Outside a Git work tree it, like every command that needs a repository, prints `environment/not_a_git_repo: <path>; run git init first` (exit 3).

**SET-2 — Order and commit.** `init` on a repository whose `.kogen/project.yaml` is not committed, in this order:

1. refuses without a Git identity (SET-5), writing nothing;
2. refuses when a path it writes has uncommitted changes: `environment/dirty_tree: <path> has uncommitted changes; commit, stash or discard them first` (exit 5). The paths are `.kogen/project.yaml`, `.gitignore` and, for a bridge (SET-13), `features/steps/README.md`. Other uncommitted changes are allowed; they stay out of the commit and out of the checks, which run on the committed tree (SET-12);
3. refuses without a login before any request (GPT-5, `provider/login: not signed in; run kogen provider login chatgpt`, exit 4);
4. detects candidate commands (SET-10) and asks the shaping model once (SET-11);
5. runs the candidates on a copy of the committed tree and keeps those that pass (SET-12), adding the bridge when needed (SET-13);
6. writes `.kogen/project.yaml` (the template below with the kept commands), appends `.kogen/local/` to the root `.gitignore`, copies the bridge files, and commits exactly those paths with a plain `git commit` (GIT-5 identity and signing rules), message `Add Kogen configuration`.

Progress lines go to stderr (`kogen: detecting the project's commands`, `kogen: asking <model>/<effort> about the project's commands`, `kogen: running setup-<n>: <command>`, `kogen: checking <name>: <command>`, `kogen: checking the acceptance runner`). Output, each list in configuration order:

```
Initialized Kogen in {abs:root}
Setup: <command>; <command>                     (or: Setup: none)
Checks: <name>, <name>                          (or: Checks: none found, or none passed when every candidate is left out)
Left out: <name> (<command>) failed with status <n>; ...    (only when a candidate failed)
Acceptance: <how>
Note: Kogen gives its models README.md only; it does not read <files>    (only when present)
Commit: {sha8} Add Kogen configuration
Next: <what to do>                              (only when something is missing)
```

`<how>` is `Cucumber bridge added in features/steps` (SET-13), `existing Cucumber runner, steps in <steps_dir>` (SET-10), or `not configured: <reason>` (SET-13). The note lists those of `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.cursor/rules` and `.github/copilot-instructions.md` that are tracked (SET-6). A left-out setup entry is named `setup-<n>`. The `Next:` lines are `Next: set commands.acceptance in .kogen/project.yaml` when acceptance is not configured and `Next: add the project's checks to commands.checks in .kogen/project.yaml` when no check was kept.

In a repository with no commit yet but with files other than `.gitignore`, `init` refuses with `environment/no_commits: <n> file(s) are not committed yet; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init` (exit 3), so the project's own first commit keeps that name and `init` can configure it. In an empty repository there is nothing to detect: `init` makes no request and writes the template unchanged; its commit is the repository's first commit, with message `Initial commit`, and the output is `Initialized Kogen in {abs:root}`, `Commit: {sha8} Initial commit (the first commit of this repository)` and both `Next:` lines.

If `git commit` fails, the written files stay uncommitted and `init` prints `environment/commit_failed: git commit failed (status <n>); the configuration is left uncommitted` plus the commit's output (exit 3).

**SET-3 — Idempotent.** On a project whose `.kogen/project.yaml` is committed, `init` changes nothing and prints `Kogen is already initialized in {abs:root}` (plus the `Next:` lines that apply), exit 0; it does not detect again. If `.kogen/project.yaml` exists uncommitted and is valid (SET-4), as a failed `init` commit leaves it, `init` commits it with the ignore line and those of the bridge paths that have uncommitted changes, without detecting again (exit 0).

**SET-4 — Invalid configuration.** Every command that reads `.kogen/project.yaml` refuses an invalid file with `environment/project_config_invalid: {abs:path}` and one `  line <n>: <message>` line per problem (exit 3). The parser is strict: unknown keys, wrong types and duplicate keys are errors. A file without a `version` key is the earlier Kogen's: every command, `init` included, refuses it before writing anything with `environment/old_kogen_config: .kogen/ is from an earlier Kogen; move it aside (git mv .kogen .kogen-old), commit, and run kogen init` (exit 3).

**SET-5 — Git identity.** Without a Git identity, `init` writes nothing and prints `environment/git_identity_missing: configure git user.name and user.email` (exit 3).

**SET-6 — Project instructions.** The root `README.md` is the project's instructions; shaping, building and reviewing give it to their models. Kogen never puts `AGENTS.md` or `CLAUDE.md` into a prompt as project instructions; the models' tools may still read any file. Kogen's testing rules are the installed `docs/testing-rules.md` (INS-2): the shaper, the builder and the reviewer each get its text, and Kogen does not copy it into the project.

**SET-7 — Local data.** Untracked per-project data lives under `.kogen/local/` (ignored): `shaping/<slug>/` (pending questions), `approvals/<slug>.json`, `runs/<build-id>/`, `build.lock`, `setup.json` (the checkout state `commands.setup` last passed for). Shaping, readiness dry runs and the approval card run `commands.setup` once per checkout state: they skip it when `setup.json` records a pass for the same setup commands, the same HEAD and the same working-tree changes outside `.kogen/` and `steps_dir` (the Intent files shaping writes), and print `kogen: setup already ran for this checkout state`. A Build always runs it (AUT-5).

## Configuration

```yaml
version: 1
commands:
  setup: []          # run before readiness dry runs and before each Build
  fix: []            # deterministic fixers, run once after each builder round
  checks: []         # project checks, e.g. {name: test, run: "mix test"}
  acceptance:
    run: null        # the acceptance command (VER-3)
    steps_dir: null  # where shaping writes step-definition files
protect: []          # check configuration the Build must not change, e.g. .credo.exs
models:
  shape:  {model: gpt-6.1-sol, effort: high}
  build:  {model: gpt-6.1-sol, effort: medium}
  review: {model: gpt-6.1-sol, effort: high}
```

**SET-8 — Commands and settings.** Each command is a string run by `/bin/sh -c` in the repository root with the caller's environment (LOOP-11). `setup` and `fix` entries are named `setup-<n>` and `fix-<n>` by their position, starting at 1. `checks` entries are `{name, run}` with unique lowercase names, and together they are the project's fast regression suite (VER-13); `acceptance` and `model` are reserved names. `protect` lists paths or globs of actual check definitions/settings (linter rules, suppression files, formatter settings) that join the acceptance baseline (VER-1), so a Build cannot pass a check by weakening its configuration. Dependency manifests and lockfiles are editable inputs when they only declare project/dependency metadata: `mix.exs`, `package.json`, nested `go.mod` and their lockfiles are not eligible solely because setup, format, compile, tests, vet or audit consumes them. A combined manifest that embeds verification settings or itself defines a configured check, such as an npm script used by a check or a Mix alias invoked by a configured command, may be protected whole-file; there is no dependency-only exception to explicit whole-file protection. Init rejects ineligible dependency-only protection with a path-specific correction request, not silent acceptance or deletion. Dedicated formatter/linter/suppression settings remain eligible. Existing committed configuration is authoritative and is not migrated. Models and efforts live only here; no command takes model or effort flags. The model identifiers are ones the ChatGPT plan serves on the official route (GPT-1). Test-only databases and services are the project's own: `commands.setup` prepares them (for example creating and migrating the test database), and a setup failure makes readiness fail; a check that needs a service that is not running fails in SET-12 and is left out. There are no Build time or token limits.

**SET-9 — Adopting Kogen in an existing project.** In this order, with no project-wide cleanup as a prerequisite:

1. `kogen provider login chatgpt`, then `kogen init`.
2. Read what `init` configured and left out (SET-10..13). Fix what you disagree with in `.kogen/project.yaml`, for example a check left out because its service was not running, and commit it.
3. Make the root `README.md` useful: purpose, how to run and check the project, conventions, links to maintained specifications, and the testing policy (`docs/testing-rules.md`). Shaping and review read it (SET-6).
4. Request one real feature or fix.
5. Shape it: the shaper inspects the implementation, callers, tests and documentation of that change and fills the specification gap around it (the desired behavior, the existing behavior it must preserve, scenarios, and a model where state or interacting rules warrant one). Existing code and tests are evidence of current behavior, not proof of intended behavior: shaping separates "the code does this now" from "the product should do this".
6. Review, approve and build. The specification grows one change at a time.


## Configuring the project

**SET-10 — Detection.** Deterministic, from the committed root files and the supported `cli/go.mod` layout:

- `mix.exs`: setup `mix deps.get`; checks `format` = `mix format --check-formatted` when `.formatter.exs` exists (then also fixer `mix format` and protect `.formatter.exs`), `compile` = `mix compile --warnings-as-errors`, `test` = `mix test`, and `credo` = `mix credo --strict` when `mix.exs` contains `:credo` (then protect `.credo.exs` when it exists).
- `package.json`: setup `npm ci --no-audit --no-fund` when `package-lock.json` exists; one check per script named `test`, `lint`, `typecheck` or `check`, run as `npm run <script>`, named after the script, or `npm-<script>` when that name is taken. npm's placeholder `test` script (`echo "Error: no test specified" && exit 1`) is not a check.
- `go.mod` or `cli/go.mod`: setup `go mod download`; checks `go-format` (no output from `gofmt -l .`), `go-test` (`go test ./...`), `go-vet` (`go vet ./...`) and `go-build` (`go build -o /dev/null ./...`). Commands for `cli/go.mod` run in `cli/`. When both modules exist, check prefixes are `go-root` and `go-cli` so names remain unique. Neither manifest nor its lockfile is protected. Other nested layouts remain available through the model proposal; this is not arbitrary module discovery.
- An acceptance runner exists when `package.json` lists `@cucumber/cucumber` in `dependencies` or `devDependencies`. Its steps folder is the first of `features/steps` and `features/step_definitions` that exists, else `features/steps`.

The acceptance command runs Cucumber on Kogen's own Node (`KOGEN_NODE`, LOOP-11). For an existing runner it is the project's own Cucumber:

```
"$KOGEN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js --strict --require '<steps_dir>/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"
```

and for the bridge (SET-13) the one Kogen ships, whose `node_modules` (`KOGEN_CUCUMBER`) also resolves the step files' `require('@cucumber/cucumber')`:

```
NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require 'features/steps/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"
```

**SET-11 — The model request.** `init` sends one request to `models.shape` of the template (`gpt-6.1-sol`, effort `high`) with: the detection result; the tracked file list; and the text of those of `README.md`, `mix.exs`, `package.json`, `Makefile`, `.tool-versions`, `.github/workflows/*.yml` and `*.yaml`, and `.gitlab-ci.yml` that exist in the committed tree, each cut as a tool result is (LOOP-8). It is told to propose the project's setup, fixers, fast checks and check definitions/settings from these sources, each check as the single command the project's own sources name (one per tool, not an aggregate alias that runs them all), and nothing the sources do not name. It answers by calling `submit_configuration` with `setup` and `fix` (lists of commands), `checks` (`{name, run}` entries with the SET-8 name rules) and `protect` (tracked paths). Before configuration is written, validation rejects each dependency-only Mix/npm/Go manifest or lockfile protect entry with a path-specific explanation; a manifest is eligible when its content defines a configured check (for example a used npm script or invoked Mix alias) or embedded verification settings, including Mix test discovery/selection and coverage settings. Dedicated settings remain eligible. An invalid reply goes back once with the problems and must be corrected, not silently accepted or deleted; a second invalid reply ends `init` with `provider/init_invalid: the model did not return a valid configuration; nothing was written` (exit 4). No writes occur on that path. Valid proposals merge as before: a proposed check replaces the detected check of the same name, the others are added after the detected ones; proposed setup entries and fixers are added after the detected ones unless already present; protect is the union. Identical check commands run once. Different command strings are retained: configured test paths and filters can make explicit path checks necessary even when `mix test` is present. The model avoids overlap only when project sources establish equivalent coverage. One-time `mix local.hex`/`mix local.rebar` bootstrap is rejected from recurring setup with correction feedback. Usage is printed as a usage line on stderr.

**SET-12 — Verification.** `init` copies the working tree to a temporary folder (copy-on-write where the file system has one, as SHP-10), restores the tracked files there to HEAD and removes untracked files that are not ignored, so the ignored dependency and build folders stay. There, with the LOOP-11 environment and no time limit, it runs the setup entries in order, each twice: setup runs before every Build, so an entry must also succeed on the tree it has already prepared. An entry whose first run exits non-zero is left out as `setup-<n> (<command>) failed with status <s>`. An entry whose second run fails, or changes any path compared with the tree after its first run (paths Git does not ignore, compared by content), is left out as `setup-<n> (<command>) is not repeatable: its second run failed with status <s>` or `... its second run changed <paths>`. Then it runs the runner check (SET-13), for the bridge or an existing runner, then each check once, in the state a repeated setup leaves, so a kept check cannot fail at every Build start. A check that exits non-zero is left out and listed under `Left out:`; the next ones still run. Fixers are not run. The copy is removed afterwards; the user's working tree changes only by the files `init` writes.

**SET-13 — Acceptance bridge.** Without an acceptance runner, `init` adds the minimal bridge: the folder `features/steps/` with `features/steps/README.md` (`Cucumber step definitions for Kogen acceptance scenarios.`, since Git keeps no empty folder) and the bridge command of SET-10, which runs the `@cucumber/cucumber` 13.3.0 Kogen ships (INS-2) on Kogen's own Node. The project installs nothing, and its existing test framework and files are not changed. The runner check, for the bridge and for an existing runner, runs the acceptance command once in the copy with `KOGEN_ACCEPTANCE_FEATURES` set to a temporary feature file holding only `Feature: Kogen acceptance runner check` and `KOGEN_ACCEPTANCE_REPORT` set to a temporary file; it passes when the command exits 0 and writes the report. If it fails, acceptance stays unset and `Acceptance: not configured: the runner check failed with status <n>` (or `... wrote no report`) says so.

Scenarios: `features/01-project-setup.feature`.
