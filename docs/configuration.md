# Configuration

Kogen reads two committed files and one optional host-local file. `kogen init` writes and commits the first two.

## `.kogen/project.yaml`

The project's commands. Init finds them, runs each once on the committed tree and keeps the ones that pass. Edit it where you disagree, then commit it.

```yaml
version: 1
commands:
  setup:                      # run before each Build and verification pass, in order
    - 'go mod download'
  fix:                        # fixers, run once after each builder round
    - 'gofmt -w .'
  checks:                     # a Build commits only when all of these pass
    - {name: format, run: 'test -z "$(gofmt -l .)"'}
    - {name: tests, run: 'go test ./...'}
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js"
      --strict --require ''features/steps/*.js''
      --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: 'features/steps'  # where shaping writes step files
protect: ['.golangci.yml']    # check settings a Build must not change
```

- `version`: always `1`.
- `commands.setup`: shell commands that prepare the tree, such as installing dependencies.
- `commands.fix`: deterministic fixers, such as a formatter.
- `commands.checks`: `{name, run}` pairs; names are unique, lowercase, with letters, digits and dashes; `acceptance` and `model` are reserved.
- `commands.acceptance.run`: the Cucumber command; Kogen sets `KOGEN_NODE`, `KOGEN_CUCUMBER`, `KOGEN_ACCEPTANCE_FEATURES` and `KOGEN_ACCEPTANCE_REPORT`.
- `commands.acceptance.steps_dir`: the folder for step files; they use `require('@cucumber/cucumber')`.
- `protect`: paths or globs of linter, formatter and similar settings; they are part of every approved baseline.

Commands run with `/bin/sh -c` in the repository root and have no time limit.
A check that already fails on the unchanged tree does not stop a Build from starting, but the Build lands only when every check passes.
For a test that fails now and then, rerun the failed tests in the same check, for example `npm test || npm test`.
Start services such as databases yourself, and put what prepares them in `setup`.
An invalid file is refused as `environment/project_config_invalid` with one `line <n>: <message>` per problem.

## `.kogen/models.yaml`

The team lineup: which model runs each role. A role the file omits keeps its default.

```yaml
models:
  shape:  {provider: chatgpt, model: gpt-6.1-sol, effort: high}
  build:  {provider: anthropic, model: claude-sonnet-5-5, effort: medium}
  review: {executor: claude-code, model: claude-opus-5-5, effort: high}
```

- `shape`: the role for Shape and Refine.
- `build`: the role that implements the Intent.
- `review`: the independent reviewer; it starts its own conversation.
- `provider`: `chatgpt`, `supergrok`, `opencode-go`, `anthropic` or `openai-compatible`; omitted means `chatgpt`.
- `executor`: `native` (the default) or `claude-code`, which runs Kogen's pinned Claude Code; it takes no `provider`.
- `model`: any nonempty name; Kogen sends it unchanged.
- `effort`: any nonempty value; for `anthropic` and `claude-code` it is `low`, `medium`, `high`, `xhigh` or `max`.
- `base_url`: the host of an `openai-compatible` role.

Defaults are `gpt-6.1-sol` at `high` for shape, `gpt-6.1-sol` at `medium` for build and `gpt-6.1-terra` at `medium` for review.
When Claude Code is your only login, init writes the `claude-code` executor for all three roles.
Each role needs its provider's login only when the role runs; see `kogen provider login` in [getting-started.md](getting-started.md).
Changing a role changes the approval baseline: approve the Intent again before the next Build.
A bad role or effort is refused as `environment/project_config_invalid`, naming the file and line.

## `.kogen/local/models.yaml`

An optional override in the same form, for one machine. Git ignores `.kogen/local/`, so it is never committed.

```yaml
models:
  build: {provider: opencode-go, model: kimi-k3, effort: high}
```

Precedence is the defaults, then `.kogen/models.yaml`, then `.kogen/local/models.yaml`.
A role in the local file replaces the whole role: here `shape` and `review` stay as the team file says.

## Where the rest is

Provider details, executor behaviour, prompt caching and ready lineups are in `spec/reference/` of the Kogen repository.
