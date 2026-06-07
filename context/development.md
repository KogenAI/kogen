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
- **Pi launcher patterns**: Shape mode produces draft pitches (not committed changes per system-prompt contract). Mode launchers: `claude-shape` uses basename resolver in pwd (stub pitch must pre-exist); `pi-shape` accepts raw prompts. Extension loading: `--no-extensions` flag silences global extension version conflicts (use before explicit `--extension` paths).

## Make Targets (Index)

One-liner per target — for test target semantics see `context/test-harness.md`; for hook-parity semantics see `context/hooks.md`.

| Target                    | Purpose                                                                                                                                                                                  |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make install`            | Gate: verify python3 + node + yq-mikefarah; then generate agents + install claude harness (full cycle); npm install root node_modules                                                    |
| `make test`               | Hook-parity + harness-parity + test-generator + enforce-registry-parity + bash hook tests (`run-tests.sh`) + scaffold run-tests — parity/structure validation only; separate from ExUnit |
| `make test-stacks`        | Run ExUnit stack scaffold tests — see `context/test-harness.md` for semantics                                                                                                            |
| `make test-stacks-claude` | Run ExUnit suite for Claude harness only                                                                                                                                                 |
| `make test-stacks-pi`     | Run ExUnit suite for Pi harness only                                                                                                                                                     |
| `make bench REASON=`      | Full benchmark run (both harnesses) + writes `summary.md` via `summarize.js`                                                                                                             |
| `make record-green`       | Stamp `last_green.json` after clean passing suite                                                                                                                                        |
| `make uninstall`          | Remove installed claude harness artifacts                                                                                                                                                |
| `make test-coverage`      | Run coverage per language → `coverage/<lang>/`                                                                                                                                           |
| `make test-generator`     | Run Python unittest + bash unit tests for generator pipeline                                                                                                                             |

## Environment Configuration

| Variable             | Purpose                      | Notes                                                                                                                                                                                                                                                                      |
| -------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CODEGEN_DIR`        | Absolute path to this repo   | Set by `config.sh`                                                                                                                                                                                                                                                         |
| `INSTALL_DIR`        | Launcher install destination | Default: `~/bin`                                                                                                                                                                                                                                                           |
| `ZSH_COMPLETION_DST` | Zsh completions destination  | Set in `config.sh`                                                                                                                                                                                                                                                         |
| `ANTHROPIC_API_KEY`  | Claude/Pi API key            | Required; not in `.env`                                                                                                                                                                                                                                                    |
| `CLAUDE_MODEL`       | Override default model       | Optional                                                                                                                                                                                                                                                                   |
| `BENCH`              | Enable benchmark capture     | Set to `1` with `make test-stacks`; requires `REASON` non-empty; must be literal non-empty string (Makefile conditional checks via `$(if var,...)` emits empty when var unset)                                                                                             |
| `REASON`             | Human-readable run label     | Required when `BENCH=1`; stored in run dir as `reason.txt`; JSON deserialization at viewer time via `String.to_atom(k)` — never use `to_existing_atom/1` on untrusted key strings (smoke test caught `ArgumentError: not an already existing atom` on `"duration_api_ms"`) |

See `.env.sample` and `.env.prod.sample` for full variable lists.

## Coding Conventions

- **Bash**: `set -euo pipefail` in all scripts; `content_stable_cp` is defined in `install.sh` (not `utils.sh`) for idempotent file copies; `utils.sh` provides only `OCG_CMD` and `open_cursor_workspace`
- **Bash sed portability**: `sed -i ''` (BSD macOS) is not portable to GNU sed (Linux). Use temp-file rewrite instead: `sed 'EXPR' file >"${file}.tmp" && mv "${file}.tmp" file`. Canonical reference: `install.sh` lines 474–483 (mktemp/cmp/mv pattern). Mutation scripts in `shared/scaffold/` use this idiom throughout.
- **Elixir module @moduledoc/@spec ordering**: credo's StrictModuleLayout requires `[:shortdoc, :moduledoc, :use, ...]` order — `@moduledoc` ALWAYS comes AFTER `defmodule ... do` and BEFORE `use`. Scaffold mutation credo_fix.sh enforces this when injecting @moduledoc into generated files.
- **Bash module name derivation**: When converting slug to CamelCase module names, use `python3` one-liner (`python3 -c '...capitalize join...'`); pure-sed BRE is fragile across BSD/GNU + bash 3.2 case-fold gaps. Reference: `scaffold.sh` line 81.
- **Python**: stdlib only in generator scripts — no third-party deps. One-liner scripts (e.g., module name derivation) can use python3 directly in Bash heredocs.
- **TypeScript**: strict mode; each extension self-contained with own `package.json`
- **Commit messages**: why-focused, delegated to committer subagent — never written directly by orchestrator

## Dev Scripts

| Script                                      | Purpose                                                             |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `install.sh <harness>`                      | Install named harness                                               |
| `uninstall.sh <harness>`                    | Remove named harness                                                |
| `harnesses/claude/hooks/run-tests.sh`       | Run all bash hook tests                                             |
| `test_harness/record-green.sh`              | Stamp `last_green.json` + tool versions (elixir, otp, node, yq, os) |
| `templates/generator/generate.sh <harness>` | Render agent prompts for harness                                    |
| `update_ai_tools.sh`                        | Update Claude CLI and AI tool deps                                  |

## Benchmark Viewer (Mix Tasks)

Run from `test_harness/`:

- `mix codegen.bench.list` — lists all runs under `codegen/benchmarks/` newest-first
- `mix codegen.bench.view --run codegen/benchmarks/<ts>` — ASCII metrics table for one run; add `--compare <prev>` for delta column

## Benchmark Prerequisites

Screenshot capture for static-stack benchmark runs requires:

- `node` — already required by vite stacks; must be on `PATH`
- `playwright` npm devDependency — pinned at `^1.60.0` in root `package.json`; install via `npm install` at repo root
- Chromium browser binary — one-time install: `npx playwright install chromium`

Missing Playwright is **non-fatal**: `BenchArtifacts.capture_screenshot/4` detects the missing module, logs `playwright not installed — skipping screenshot capture`, and returns `:ok`. JSONL bench records are always written regardless of screenshot availability.

## Common Pitfalls

- **`make install` gated on python3, node, yq-mikefarah** — fresh-box installs fail loud if build-critical tools missing (not jq/rg, which install.sh installs). Verify `yq --version | grep -qi mikefarah`; `apt install yq` installs python-yq (incompatible, silently wrong manifest parsing) — use mikefarah/yq binary instead.
- **`npm install` at codegen root required before hook use** — root `node_modules/` (ajv, playwright, prettier) must exist for schema-validate.js and render-check.js; install.sh now runs this automatically. If absent, verification hooks emit INCONCLUSIVE (cannot run, not passed).
- **`make install` required after any rule/template change** — running agents see the old baked prompts otherwise
- **Root node_modules absence is a trap** — hooks silently degrade (INCONCLUSIVE verdict) if ajv/playwright unresolvable. Run `npm install` at codegen root or rely on install.sh to do it.
- **`mise trust` runs unconditionally on install** — enforcement `.mise.toml` is now trusted without `OCG_NONINTERACTIVE` gate; interactive installs no longer hang on trust prompt.
- **Do not run `npm install` at repo root for Pi extensions** — each extension has its own node_modules; run per-extension dir (only root install is managed by install.sh)
- **Hook test failures are not ExUnit** — `make test` runs bash tests; `make test-stacks` runs ExUnit; they are separate suites
- **`CODEGEN_DIR` must be absolute** — relative paths break symlink resolution in launchers

## Deployment / Distribution

Codegen runs on servers too — combobulate prod/staging and the Hetzner dashboard box all run codegen, in addition to operator Macs. Distribution = `make install` on each machine (server or Mac); each derives its root from `BASH_SOURCE`, never hardcoded. CI validates that scaffold output compiles and hook tests pass. PRs require both `make test` and `make test-stacks` green before merge. See `context/deployment-topology.md`.
