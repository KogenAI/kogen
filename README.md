# Kogen

Kogen takes one requested feature through five steps in your own Git repository:

1. **Shape**: a model writes the feature as short prose, executable Gherkin with step definitions, and a Quint model when the change has meaningful state. It asks you only about open UI/UX choices.
2. **Build**: after you approve the exact files, Kogen's own model/tool loop implements it.
3. **Verify**: the acceptance scenarios run against the real code, with the model check and the project's checks; failures go back to the builder until everything passes.
4. **Review and fix**: an independent reviewer investigates and repairs concrete defects. Kogen verifies changed final files; failures stay with that reviewer. Maintenance preferences are notes. An unresolved substantive blocker stops with preserved work instead of restarting the builder/review loop.
5. **Commit**: one commit of exactly the verified and reviewed contents, with your own Git configuration.

ChatGPT ("Sign in with ChatGPT", using your plan) is the only provider. Kogen is the small core the rest of Kogen is built with: further features can be built through Kogen or developed directly while the tool is being qualified.

## Status

Kogen is in active development. There is no published release yet: you build the release archive from this repository. It runs on macOS on Apple Silicon and on Linux x86-64 with glibc. Release qualification requires the deterministic suite on both platforms and real use: the installed candidate builds a feature in the example app in `examples/` and a change to Kogen itself. Uncommitted local builds remain development candidates until those gates pass.

## Getting started

You need Git, a ChatGPT plan, and the toolchain in `.tool-versions` (Elixir 1.20.4 on Erlang/OTP 29.1.1, Go 1.27, Node 24; for example with [mise](https://mise.jdx.dev): `mise install`).

```sh
mix local.hex --force                          # Elixir's package manager, once per machine
sh packaging/package.sh                        # builds dist/kogen-<version>-<platform>.tar.gz
tar -xzf dist/kogen-*.tar.gz -C /tmp
sh /tmp/kogen-*/install.sh                     # installs into ~/.local; needs no administrator rights
export PATH="$HOME/.local/bin:$PATH"           # if install.sh says ~/.local/bin is not on your PATH
kogen provider login chatgpt                   # signs in through your browser
```

Then, in a Git repository of your own with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it):

```sh
kogen init                                     # finds and checks the project's commands, commits .kogen/project.yaml
kogen intent shape my-feature ../request.md    # the request, kept outside the repository; answer questions on stdin: printf '1: a\n' | kogen intent shape my-feature -
kogen intent approve my-feature                # shows the card; approve with the hash it prints
kogen intent build my-feature                  # builds, verifies, reviews and commits
```

To correct an existing **ready** package without regenerating it, take the full SHA-256 from `kogen intent approve <slug>` and run `kogen intent refine <slug> <sha256> ../correction.md`. It changes existing owned files only, checks the merged package in scratch and preserves the original on refusal/failure. New/deleted files, shared step edits, changed acceptance paths and model addition/removal need a new shaping request. For an approved package, first preserve and stash unfinished implementation changes; only the normal Build-clean paths are allowed. Its approval must match the full current hash. A successful correction archives and revokes that approval; failure retains it. Refinement never approves; review and approve its resulting package normally. Evidence stays under `.kogen/local/refinements/`.

For a generated project, commit the runnable scaffold first; `kogen init` then makes a separate `Add Kogen configuration` commit. A truly empty Git worktree can instead start with a configuration-only `Initial commit`; uncommitted application files must be committed before initialization. An uncommitted request belongs outside the repository.

`kogen init` keeps only the checks that pass on your committed tree, and sets up acceptance with the Cucumber Kogen ships, or with the project's own; [docs/configuration.md](docs/configuration.md) explains `.kogen/project.yaml`. Dependency manifests and lockfiles (such as `mix.exs`, `package.json`, `go.mod` and their lockfiles) are editable inputs when they only describe project/dependency metadata. Dedicated formatter, linter and suppression settings remain protected. A combined manifest that defines a configured check, such as an npm check script or a Mix check alias, may be protected whole-file; it then has no dependency-only edit exception. If shaping reports a genuine conflict, revise the request, or review and commit `.kogen/project.yaml` outside Build and shape again. This manual review changes the approval baseline; it is not approval to edit a protected file in Build. Preserve checks and their actual configuration. `kogen help` lists every command, and `kogen uninstall` removes the program.

## Specification

[spec/](spec/README.md) is the specification this repository implements: prose chapters with numbered requirements, Gherkin scenarios for every requirement, and Quint models of the state machines.

## Development

Set up once, with the toolchain from `.tool-versions` on `PATH`:

```sh
mix local.hex --force
mix deps.get
(cd spec && npm ci)
(cd test/acceptance && npm ci)
```

Checks for an ordinary change, as [docs/testing-strategy.md](docs/testing-strategy.md) describes (the tests a change needs follow [docs/testing-rules.md](docs/testing-rules.md)):

```sh
mix test test/kogen                            # unit tests
mix test test/integration                      # integration tests against a freshly installed release
(cd cli && go test -race ./...)                # Go tests of the kogen command
(cd spec && sh check.sh)                       # the specification's own checks
sh packaging/package.sh                        # the release the scenarios install (they use the newest in dist/)
(cd test/acceptance && npx cucumber-js --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" ../../spec/features/04-building.feature)   # the chapter you changed
```

Release checks:

```sh
sh test/suite.sh                               # every deterministic layer and scenario; run on macOS and Linux
sh test/live/real-use.sh example file://$PWD/dist/<archive>   # real use on the example app (REL-1)
sh test/live/self-repo.sh /tmp/kogen-self && KOGEN_SELF_REPO=/tmp/kogen-self sh test/live/real-use.sh kogen file://$PWD/dist/<archive>   # installed self-hosting qualification attempt (REL-1)
sh test/live/self-build-check.sh <run folder>/project      # REL-3 on what that run landed; real-use.sh prints the run folder
sh examples/tiny_tasks-qualification/qualify.sh               # qualifies the example app's own checks
```

During development, fix Kogen directly with an external coding agent when needed. Self-hosting is a qualification path, not a prerequisite for repairing the tool. Preserve failed-attempt evidence and verify the candidate independently. An uncommitted development build is not a qualified release; the release checks above still apply.

The scenarios run Python from `.tool-versions`; set `KOGEN_TEST_PYTHON_BIN` to use another Python 3.13. `sh test/suite.sh` takes about two minutes with dependencies installed.

## Folder map

| Path | What |
| --- | --- |
| `lib/` | the Elixir core (`Kogen.Application`): shaping, ChatGPT, the build loop, verification, review, commit |
| `config/`, `rel/` | the core's configuration and release settings |
| `cli/` | the Go `kogen` command: arguments, the bridge to the core, project commands in process groups, the login listener |
| `packaging/` | `package.sh`, `install.sh`, the release README, the pinned Quint and Cucumber packages, third-party licences |
| `spec/` | prose, Gherkin and Quint specification, and its checks |
| `docs/` | `configuration.md`, `testing-rules.md` (the test-selection rules Kogen gives its models and follows itself), `testing-strategy.md` (Kogen's own test layers and gates) |
| `examples/` | the example app for real-use tests, with the qualification of its checks |
| `test/kogen/`, `test/integration/` | ExUnit unit and integration tests |
| `test/acceptance/` | the deterministic scenario suite: step definitions, the fake ChatGPT server, fixtures |
| `test/live/` | release acceptance (real use), the product export and its checks |

## Contact

contact@kogen.dev

## License

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE); see [NOTICE](NOTICE). The release archive bundles third-party software under their own licences: [packaging/licenses/](packaging/licenses/README.md).
