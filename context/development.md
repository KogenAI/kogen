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

## Gate Terminology Clarification

**`make ci`** in a codegen scaffold context is the DOWNSTREAM generated app's gate — not the codegen repo's own gate. `scaffold.sh` runs `make ci` on the generated app's output to validate the scaffold produced a compilable, testable structure.

**THIS REPO's gate** is `make test` (codegen self-test: hook parity, generator tests, hermetic ExUnit). The codegen Makefile has no `make ci` target; CI validation is downstream-only.

**`make test-stacks`** (slow, real LLM) validates full stack output including the downstream `make ci` gate. The distinction:

- `make test` — codegen repo self-checks (fast, hermetic)
- `make test-stacks` — full end-to-end with real LLM + downstream-app `make ci` validation (slow)
- Downstream `make ci` — generated app's gate (called by scaffold.sh, not codegen repo itself)

## Make Targets (Index)

One-liner per target — for test target semantics see `context/test-harness.md`; for hook-parity semantics see `context/hooks.md`.

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

**`CODEGEN_BUILD_*` operator-toggle convention**: Build-time flags exported as `export CODEGEN_BUILD_<FLAG>="${<FLAG>:-}"`, read by `dispatch.sh` via `${CODEGEN_BUILD_<FLAG>:-}`. Honor-empty: explicit empty string passes through. Use `"${VAR:-}"` for `set -u`-safe export/import. Example: `export CODEGEN_BUILD_RESUMABLE="${RESUMABLE:-}"`, read back as `RESUMABLE="${CODEGEN_BUILD_RESUMABLE:-}"`.

## Coding Conventions

- **Bash**: `set -euo pipefail` in all scripts; `content_stable_cp` defined in `install.sh` (not `utils.sh`) for idempotent file copies; `utils.sh` provides only `OCG_CMD`.
- **Bash sed portability**: `sed -i ''` (BSD macOS) not portable to GNU sed (Linux). Use temp-file rewrite: `sed 'EXPR' file >"${file}.tmp" && mv "${file}.tmp" file`. Canonical: `install.sh` lines 474–483 (mktemp/cmp/mv pattern). Mutation scripts in `shared/scaffold/` use this idiom throughout.
- **Multi-line block composition**: `printf "%b"` interprets `\n` in format+args, BUT `$()` strips trailing newlines. String concatenation + `%b` is fragile. Prefer `{ printf ...; printf ...; } >> file` for block writes.
- **Bash subshell export isolation**: Pipe subshells (`printf ... | fn`) execute in a subshell — exports + variable mutations invisible to outer process. Fix: use file redirect (`while ... done < file` or `fn < "$stdin_file"`) instead of pipe. Redirect keeps the loop/process in the current shell so `CONTEXT_FLAGS`, `ROLE_SYSTEM_PROMPT`, `TIER0_LOADED`, and similar mutations persist. Write input to temp file if needed, never pipe data through a loop.
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

## Benchmark Viewer (Mix Tasks)

Run from `test_harness/`:

- `mix codegen.bench.list` — lists all runs under `codegen/benchmarks/` newest-first
- `mix codegen.bench.view --run codegen/benchmarks/<ts>` — ASCII metrics table for one run; add `--compare <prev>` for delta column

## Benchmark Prerequisites

Screenshot capture for static-stack benchmark runs requires:

- `node` — must be on `PATH`
- `playwright` npm devDependency — pinned at `^1.60.0` in root `package.json`; install via `npm install` at repo root
- Chromium browser binary — `make install` guarantees this on static-capable boxes; `make doctor` verifies. Manual install: `npx playwright install chromium`

**Two separate subsystems with different failure modes**:

1. **Benchmark screenshots** — `BenchArtifacts.capture_screenshot/4` (ExUnit test phase). Missing Playwright is **non-fatal**: logs warning and returns `:ok`. JSONL bench records always written.
2. **Static-site render gate** — `static-site-build-check.sh` (SubagentStop hook). **Fail-closed**: Chromium absent on a static-capable box blocks the developer subagent. The gate requires Chromium; benchmarks tolerate its absence.

## Runtime Porting — Reduced Fidelity Across Harnesses

When porting a guard/hook from Claude (Bash) to Pi (TypeScript), the runtime capabilities may differ:

- **Transcript access**: Claude has JSONL transcript inspection via `jq` + `TRANSCRIPT_PATH`; Pi has no transcript. Guards depending on transcript-based detection cannot be ported with full fidelity. Write a reduced-fidelity observe-only twin with disk-scan heuristics + explicit header comment documenting the gap.
- **Event blocking asymmetry**: Claude's Stop event can block; Pi's `session_shutdown` is observe-only. All 4 Stop/SubagentStop twins emit stderr warnings, NEVER `block()`.

The goal is truthful hooks that accurately reflect capability limits, not feature parity claims that hide missing capabilities.

## Scaffold File Rendering Order

Integrate-stage renders (PROJECT_CONTEXT, restart_server.sh, usage_rules_INDEX) run BEFORE the git commit (codegen-scaffold do_create):

1. Stack-specific scaffold.sh completes file writes
2. `run_integrate_stage` renders cross-stack files from templates
3. Git commit runs after integrate-stage (single commit point for both stacks)
4. Atomic mv from temp parent to final location

This eliminates the dirty-tree race: integrate-stage files rendered AFTER the commit → `git status --porcelain` non-empty → build failure.

## Pitfalls & Bash Gotchas

→ See `context/pitfalls.md` for codegen-infra pitfalls and bash gotchas.
