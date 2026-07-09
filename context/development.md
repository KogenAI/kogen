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
- **Pi launcher patterns**: Shape mode produces draft pitches (not committed changes per system-prompt contract). Mode launchers: `claude-shape` and `pi-shape` both resolve draft basenames in pwd and start the shaping loop autonomously; Claude uses `@`-mentions, Pi uses `shape codegen/pitches/draft/<slug>.md`. Extension loading: `--no-extensions` flag silences global extension version conflicts (use before explicit `--extension` paths).

## Gate Terminology Clarification

**`make ci`** in a codegen scaffold context is the DOWNSTREAM generated app's gate — not the codegen repo's own gate. `scaffold.sh` runs `make ci` on the generated app's output to validate the scaffold produced a compilable, testable structure.

**THIS REPO's gate** is `make test` (codegen self-test: hook parity, generator tests, hermetic ExUnit). The codegen Makefile has no `make ci` target; CI validation is downstream-only.

**`make test-stacks`** (slow, real LLM) validates full stack output including the downstream `make ci` gate. The distinction:

- `make test` — codegen repo self-checks (fast, hermetic)
- `make test-stacks` — full end-to-end with real LLM + downstream-app `make ci` validation (slow)
- Downstream `make ci` — generated app's gate (called by scaffold.sh, not codegen repo itself)

## Make Targets (Index)

One-liner per target — for test target semantics see `context/test-harness.md`; for hook-parity semantics see `context/hooks.md`. **Launcher-test discovery**: `harnesses/claude/hooks/*_test.sh` files are auto-discovered by `run-tests.sh` (grep footer `N passed, N failed`); launcher helper tests in `harnesses/shared/*_test.sh` are NOT auto-discovered — they run via the `harness-parity` target's explicit `for t in` list (Makefile ~L145-152). New launcher test → add a list entry; `harness-parity` checks each test's EXIT CODE (rc -ne 0 → FAIL).

| Target                    | Purpose                                                                                                                                                                    |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make install`            | Gate: verify python3 + node + yq-mikefarah; then generate agents + install claude harness (full cycle); npm install root node_modules                                      |
| `make test`               | Hook-parity + harness-parity + test-generator + enforce-registry-parity + bash hook tests (`run-tests.sh`) + `test-hermetic` (ExUnit `--exclude slow`) — no LLM, fast gate |
| `make test-hermetic`      | Fast ExUnit only (`mix test --exclude slow` in test_harness); deterministic guards (render-check, call-contract); no LLM, no browser; component of `make test`             |
| `make test-stacks`        | Full ExUnit suite (`mix test --only slow` in test_harness); slow gate with real LLM calls — see `context/test-harness.md` for semantics                                    |
| `make test-stacks-claude` | ExUnit suite for Claude harness only (`mix test --only slow`); slow, real LLM                                                                                              |
| `make test-stacks-pi`     | ExUnit suite for Pi harness only (`mix test --only slow`); slow, real LLM                                                                                                  |
| `make bench REASON=`      | Full benchmark run (both harnesses) + writes `summary.md` via `summarize.js`                                                                                               |
| `make record-green`       | Stamp `last_green.json` after clean passing `make test-stacks` suite                                                                                                       |
| `make uninstall`          | Remove installed claude harness artifacts                                                                                                                                  |
| `make test-coverage`      | Run coverage per language → `coverage/<lang>/`                                                                                                                             |
| `make test-generator`     | Run Python unittest + bash unit tests for generator pipeline                                                                                                               |

**`rule-render-freshness` gate**: `make test` includes a `rule-render-freshness` target (Makefile lines 479–501) that re-renders all `shared/apps/*.j2` templates via `process_template.py` + prettier and diffs against the committed `shared/apps/*.md` files. A STALE verdict means the committed files don't match a fresh render — i.e., a rule or template changed without re-running `make install`. This is a distinct gate from ExUnit and hook tests; a FAILED `make test` log may show multiple failure blocks from different subsystems.

## Environment Configuration

| Variable             | Purpose                      | Notes                                                                                                                                                                                                                                                                      |
| -------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CODEGEN_DIR`        | Absolute path to this repo   | Set by `config.sh`                                                                                                                                                                                                                                                         |
| `INSTALL_DIR`        | Launcher install destination | Default: `~/bin`                                                                                                                                                                                                                                                           |
| `ZSH_COMPLETION_DST` | Zsh completions destination  | Set in `config.sh`                                                                                                                                                                                                                                                         |
| `ANTHROPIC_API_KEY`  | Claude/Pi API key            | Not required — auth is CLI OAuth (`~/.claude.json`); dispatchers unset it (`env -u`) for hermetic builds                                                                                                                                                                    |
| `CLAUDE_MODEL`       | Override default model       | Optional                                                                                                                                                                                                                                                                   |
| `BENCH`              | Enable benchmark capture     | Set to `1` with `make test-stacks`; requires `REASON` non-empty; must be literal non-empty string (Makefile conditional checks via `$(if var,...)` emits empty when var unset)                                                                                             |
| `REASON`             | Human-readable run label     | Required when `BENCH=1`; stored in run dir as `reason.txt`; JSON deserialization at viewer time via `String.to_atom(k)` — never use `to_existing_atom/1` on untrusted key strings (smoke test caught `ArgumentError: not an already existing atom` on `"duration_api_ms"`) |

See `.env.sample` and `.env.prod.sample` for full variable lists.

**OCG\_\* platform-injected variable convention**: `OCG_<CATEGORY>_<PURPOSE>` naming; consumed-only (injected by orchestrator, never set by codegen). Group all `OCG_*` vars under a single comment block in `.env.sample` + `.env.prod.sample`; append new vars to that block. Existing examples: `OCG_APPS_ROOT`, `OCG_PHOENIX_SEED_DIR`, `OCG_USER_FILES_DIR`.

**`CODEGEN_BUILD_*` operator-toggle convention**: Build-time flags exported as `export CODEGEN_BUILD_<FLAG>="${<FLAG>:-}"`, read by `dispatch.sh` via `${CODEGEN_BUILD_<FLAG>:-}`. Honor-empty: explicit empty string passes through. Use `"${VAR:-}"` for `set -u`-safe export/import.

**The Elixir orchestration loop is the sole/unconditional build engine.** `dispatch.sh` (both harnesses) always execs `mix codegen.loop --harness=<harness> --stack=<stack> --cwd=<cwd>`; there is no engine flag, no legacy self-orchestrating harness session, and no resumable/non-interactive toggle on `codegen-build`. The `--queue` leg of `claude-build.sh`/`pi-build.sh` always execs `mix codegen.loop.queue` — the Elixir multi-pitch drain: `CodegenTestHarness.LoopQueueDrain.drain/1` (`test_harness/lib/codegen_test_harness/loop_queue_drain.ex`) — see `context/test-harness.md` § Orchestration Loop.

## Coding Conventions

- **Bash**: `set -euo pipefail` in all scripts; `content_stable_cp` defined in `install.sh` (not `utils.sh`) for idempotent file copies; `utils.sh` provides only `OCG_CMD`. **`Edit replace_all: true` on indentation-sensitive duplicate lines**: When lines with identical text but DIFFERENT indentation exist (e.g., 8 spaces vs 4 spaces), a single `replace_all: true` edit may match only one — success messaging is unreliable. Always verify via post-edit `grep -c` or `grep -n` to confirm BOTH sites changed; catch partial edits early.
- **Bash sed portability**: `sed -i ''` (BSD macOS) not portable to GNU sed (Linux). Use temp-file rewrite: `sed 'EXPR' file >"${file}.tmp" && mv "${file}.tmp" file`. Canonical: `install.sh` lines 474–483 (mktemp/cmp/mv pattern). Mutation scripts in `shared/scaffold/` use this idiom throughout.
- **Multi-line block composition**: `printf "%b"` interprets `\n` in format+args, BUT `$()` strips trailing newlines. String concatenation + `%b` is fragile. Prefer `{ printf ...; printf ...; } >> file` for block writes.
- **Bash subshell export isolation**: Pipe subshells (`printf ... | fn`) execute in a subshell — exports + variable mutations invisible to outer process. Fix: use file redirect (`while ... done < file` or `fn < "$stdin_file"`) instead of pipe. Redirect keeps the loop/process in the current shell so `CONTEXT_FLAGS`, `ROLE_SYSTEM_PROMPT`, `TIER0_LOADED`, and similar mutations persist. Write input to temp file if needed, never pipe data through a loop.
- **Test recipe hermetic git config**: The `test:` Makefile recipe (search `GIT_CONFIG_COUNT=1` in `Makefile`) exports `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false` before test invocations. This disables gpg signing in backgrounded test processes without touching the developer's `~/.gitconfig`, ensuring hermetic test commits under parallel load. Required when test runs spawn subprocesses that create git commits (e.g., fixture setup, hook tests). Pattern: `@set -e; \ export GIT_CONFIG_COUNT=1 ... ; \ ...test_command...`
- **Elixir module @moduledoc/@spec ordering**: credo's StrictModuleLayout requires `[:shortdoc, :moduledoc, :use, ...]` — `@moduledoc` ALWAYS after `defmodule ... do` and BEFORE `use`. Scaffold mutation credo_fix.sh enforces this.
- **Bash module name derivation**: Use `python3` one-liner for slug→CamelCase; pure-sed BRE is fragile across BSD/GNU + bash 3.2 case-fold gaps. Reference: the `app_module` derivation block in `scaffold.sh` (search `app_module=`).
- **Finding byte-identical lines across two files**: `comm -12 <(sort file1) <(sort file2)` — intersection idiom. Primary use: detecting harness header drift; used by `tools-header-no-dup_test.sh`.
- **Anchoring to exact text, not line numbers**: Always anchor Edits to exact phrases (never line numbers); they drift as files evolve. For ordered lists, anchor to the TEXT of the current first item (not the section header). For session logs, anchor to text DIRECTLY under the intended H2 header to avoid inserting into a sibling section.
- **Parallel Read then parallel Edits**: For independent single-line insertions into different files, Read all targets in parallel first to confirm anchors, then execute all Edits in parallel.
- **Scaffold.sh Phase pattern for new directories**: Canonical model is Phase 3 (`priv/plts` + `.keep` file): `mkdir -p` + `touch .gitkeep` + echo status message.
- **Python**: stdlib only in generator scripts — no third-party deps. **YAML escape decoding**: when parsing YAML files that contain double-quoted strings with escape sequences (e.g., `\\s`, `\\b` in regex patterns), decode via `val.encode('latin-1').decode('unicode_escape')` to convert YAML-escaped form to the intended Python pattern. Raw `read_text()` yields double-escaped strings that fail regex matching.
- **TypeScript**: strict mode; each extension self-contained with own `package.json`. **Test isolation**: capture stderr/stdout at test-body scope, not `beforeEach`/`afterEach`; restore in finally on both paths. **Regex anchors**: JS has no `\z`; use string-split extraction. **Markdown parsing**: prefer `split("## ")` + slice over regex. **TS try/catch fail-open**: wrap entire resolution chain in one `try/catch` → exit 0 (allow); no per-step null guards. **Byte-count parity Bash↔TS**: use `Buffer.byteLength(blob, "utf8")` not `string.length` (UTF-16 units ≠ bytes). **`process.chdir()` in tests**: add `{ concurrency: 1 }` to `describe()` (Node 22+).

- **Makefile `@bash -c 'source <lib>; <fn> <args>'`** — clean pattern for invoking sourced bash library functions from make targets without a wrapper script. Hard-tab recipe lines required.
- **Commit messages**: why-focused, delegated to committer subagent — never written directly by orchestrator
- **Session log body placement**: Anchor insertions to text DIRECTLY UNDER the intended `## ` header, never to text below a sibling section — misplaced content silently breaks hook parsing. Pattern: locate exact text immediately after the target header, use as `old_string`.

## Dev Scripts

| Script                                      | Purpose                                                             |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `install.sh <harness>`                      | Install named harness                                               |
| `uninstall.sh <harness>`                    | Remove named harness                                                |
| `harnesses/claude/hooks/run-tests.sh`       | Run all bash hook tests                                             |
| `test_harness/record-green.sh`              | Stamp `last_green.json` + tool versions (elixir, otp, node, yq, os) |
| `templates/generator/generate.sh <harness>` | Render agent prompts for harness                                    |
| `update_ai_tools.sh`                        | Update Claude CLI and AI tool deps                                  |

Benchmark viewer (mix tasks), benchmark prerequisites (playwright/Chromium, two-subsystem failure modes) → `context/test-benchmarking.md`.

Runtime porting (reduced fidelity across Claude/Pi harnesses) → `context/harnesses.md`.

Three-repo coordination ordering (context → codegen → platform) → `context/deployment-topology.md`.

Scaffold file rendering order (integrate-stage vs commit sequencing) → `context/scaffold.md`.

## Developer Test Budget — `developer-no-self-gate` Constraint

The `developer-no-self-gate` hook caps developer at 3 test-command invocations per session. Each of these counts toward the budget: `make test`, `mix test`, bare `mix test --exclude slow`, `mix format && mix compile` (combined, still one call). **Note**: `mix format && mix compile` on the same Bash line consumes ONE budget slot (same as a single `mix test`), not two. When budget is tight, front-load the actual full test run early, or combine multiple checks into one Bash invocation (e.g., `mix format && mix test` rather than format in one call and test in another). **Shell loops in a single Bash call burn budget per invocation**: `for i in 1 2 3; do mix test; done` burns all 3 calls in one Bash invocation. Use explicit repeat flags (e.g., `--repeat-until-failure N`) instead of shell loops to conserve budget for mandatory multi-run verification sequences.

Elixir seam threading (preserving test-override capacity) + RoleResolver shape-change sibling-test ripple → `context/test-harness-pitfalls.md`.

## Trigger Keywords

make install, make test, make test-stacks, CI/CD, Makefile, contribution, README, env vars, harness-parity, launcher tests, Makefile for t in list, dev loop, tech stack, coding conventions, developer-no-self-gate, test budget
