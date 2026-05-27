# Development, Testing & Operations

The codegen repo is a Bash + Python + TypeScript + Elixir toolchain. Primary dev loop: edit source → `make install` → test manually with `claude-build` / `pi-build`. Automated tests: bash hook tests (`run-tests.sh`) and ExUnit stack tests (`make test-stacks`).

## Tech Stack

- **Generator**: Bash + Python 3 (`process_template.py`, `hook_registrations.py`, `manifest-lib.sh`)
- **Extensions**: TypeScript / npm (Pi extensions in `harnesses/pi/pi-extensions/`)
- **Test harness**: Elixir / ExUnit (`test_harness/`)
- **Hook tests**: Bash (`*_test.sh` via `harnesses/claude/hooks/run-tests.sh`)
- **Runtime tools**: `yq` (YAML parsing), `jq` (JSON), `rg` (ripgrep), `mise` (tool version manager)
- **Coverage tooling**: ExCoveralls (Elixir — `mix coveralls.json`), c8 (TypeScript `node --test` in enforcement+subagents), vitest+istanbul (TypeScript vitest in askuserquestion), kcov (shell — `brew install kcov`), coverage.py (Python — `pip3 install -r templates/generator/requirements-dev.txt`)
- **Python testing**: stdlib `unittest` in `templates/generator/tests/`; runner: `python3 -m unittest discover -s tests`; coverage: `coverage.py` → `coverage/python/`. Version check: `python3 -m coverage --version` (not `__version__` attribute on ARM py3.14+).
- **Shell testing**: bash-native `*_test.sh` files with `assert_eq` + `N passed, N failed` summary; runner mirrors `harnesses/claude/hooks/run-tests.sh`. MacOS: system bash is 3.2 (no `${VAR@L}` case-fold, no `declare -A`); use `tr '[:upper:]' '[:lower:]'` and direct key=value loops.
- **Mix/Elixir**: ExCoveralls in `test_harness/mix.exs` uses `cli/0 [preferred_envs: ...]` (Mix 1.19+), not deprecated `preferred_cli_env` in `project/0`.
- **Pi launcher patterns**: Shape/refactor modes produce draft pitches (not committed changes per system-prompt contract). Mode launchers: `claude-{shape,refactor}` use basename resolver in pwd (stub pitch must pre-exist); `pi-{shape,refactor}` accept raw prompts. Extension loading: `--no-extensions` flag silences global extension version conflicts (use before explicit `--extension` paths).

## Make Targets (Index)

One-liner per target — for test target semantics see `context/test-harness.md`; for hook-parity semantics see `context/hooks.md`.

| Target                    | Purpose                                                                       |
| ------------------------- | ----------------------------------------------------------------------------- |
| `make install`            | Generate agents + install claude harness (full cycle)                         |
| `make install-pi`         | Generate + install pi harness                                                 |
| `make test`               | Run bash hook tests (`run-tests.sh`) — separate from ExUnit                   |
| `make test-stacks`        | Run ExUnit stack scaffold tests — see `context/test-harness.md` for semantics |
| `make test-stacks-claude` | Run ExUnit suite for Claude harness only                                      |
| `make test-stacks-pi`     | Run ExUnit suite for Pi harness only                                          |
| `make record-green`       | Stamp `last_green.json` after clean passing suite                             |
| `make gate-status`        | Check in-flight gate process status                                           |
| `make uninstall`          | Remove installed claude harness artifacts                                     |
| `make test-coverage`      | Run coverage per language → `coverage/<lang>/`                                |
| `make test-generator`     | Run Python unittest + bash unit tests for generator pipeline                  |

## Environment Configuration

| Variable             | Purpose                      | Notes                   |
| -------------------- | ---------------------------- | ----------------------- |
| `CODEGEN_DIR`        | Absolute path to this repo   | Set by `config.sh`      |
| `INSTALL_DIR`        | Launcher install destination | Default: `~/bin`        |
| `ZSH_COMPLETION_DST` | Zsh completions destination  | Set in `config.sh`      |
| `ANTHROPIC_API_KEY`  | Claude/Pi API key            | Required; not in `.env` |
| `CLAUDE_MODEL`       | Override default model       | Optional                |

See `.env.sample` and `.env.prod.sample` for full variable lists.

## Coding Conventions

- **Bash**: `set -euo pipefail` in all scripts; `content_stable_cp` from `utils.sh` for idempotent file copies
- **Python**: stdlib only in generator scripts — no third-party deps
- **TypeScript**: strict mode; each extension self-contained with own `package.json`
- **Commit messages**: why-focused, delegated to committer subagent — never written directly by orchestrator

## Dev Scripts

| Script                                      | Purpose                            |
| ------------------------------------------- | ---------------------------------- |
| `install.sh <harness>`                      | Install named harness              |
| `uninstall.sh <harness>`                    | Remove named harness               |
| `harnesses/claude/hooks/run-tests.sh`       | Run all bash hook tests            |
| `test_harness/record-green.sh`              | Stamp last_green.json              |
| `templates/generator/generate.sh <harness>` | Render agent prompts for harness   |
| `update_ai_tools.sh`                        | Update Claude CLI and AI tool deps |

## Common Pitfalls

- **`make install` required after any rule/template change** — running agents see the old baked prompts otherwise
- **`yq` version matters** — `manifest-lib.sh` uses yq v4 syntax; v3 will silently return wrong values
- **Do not run `npm install` at repo root for Pi extensions** — each extension has its own node_modules; run per-extension dir
- **Hook test failures are not ExUnit** — `make test` runs bash tests; `make test-stacks` runs ExUnit; they are separate suites
- **`CODEGEN_DIR` must be absolute** — relative paths break symlink resolution in launchers

## Deployment / Distribution

No server deployment. Distribution = `make install` on each developer machine. CI validates that scaffold output compiles and hook tests pass. PRs require both `make test` and `make test-stacks` green before merge.
