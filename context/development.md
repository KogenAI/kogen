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

**`CODEGEN_BUILD_*` operator-toggle convention**: Build-time flags exported as `export CODEGEN_BUILD_<FLAG>="${<FLAG>:-}"`, read by `dispatch.sh` via `${CODEGEN_BUILD_<FLAG>:-}`. Honor-empty: explicit empty string passes through. Use `"${VAR:-}"` for `set -u`-safe export/import. Example: `export CODEGEN_BUILD_RESUMABLE="${RESUMABLE:-}"`, read back as `RESUMABLE="${CODEGEN_BUILD_RESUMABLE:-}"`. **`harnesses/shared/build-queue.sh` is LIVE** — it is the default (non-`--elixir`) `--queue` drainer, invoked directly by `claude-build.sh`/`pi-build.sh` (not via dispatch.sh's exec-env); it reads its own per-pitch budget toggles from the ambient operator environment. The Elixir multi-pitch drain is a separate, parallel engine: `CodegenTestHarness.LoopQueueDrain.drain/1` (`test_harness/lib/codegen_test_harness/loop_queue_drain.ex`), invoked via `mix codegen.loop.queue` — see `context/test-harness.md` § Orchestration Loop. Dispatch remains a distinct consumer for in-agent env vars; do not duplicate queue-specific toggles as dispatch exports (dead config with no consumer).

**`CODEGEN_BUILD_ELIXIR`**: engine selector, set by `codegen-build --elixir`. Present (non-empty) → both `dispatch.sh` scripts route the one-shot build to `mix codegen.loop` (the deterministic Elixir orchestration loop). Absent (default) → the legacy self-orchestrating harness session runs instead. This decouples engine choice from `CODEGEN_BUILD_NON_INTERACTIVE`, which is now legacy-engine-I/O-mode-only (headless stream-json vs interactive UI) — there is no TTY auto-detection; both flags are independent, explicit, caller-set booleans. `--elixir` cannot combine with `--resume-id`/`--resumable` (the loop is not resumable) — `codegen-build` rejects the combination with a usage error before dispatch runs. The `--queue` leg of `claude-build.sh`/`pi-build.sh` mirrors this same gate: bare `--queue` (no `--elixir`) execs the legacy `harnesses/shared/build-queue.sh` drainer; `--elixir --queue` execs `mix codegen.loop.queue` instead.

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

## Three-Repo Coordination Ordering

Order: context → codegen → platform. Deploy docs show actual SSH invocations verbatim, not prose. Each repo committed before next. ❌ Bundle changes across repos in prose ✅ Numbered SSH/git commands.

## Scaffold File Rendering Order

Integrate-stage renders (PROJECT_CONTEXT, restart_server.sh, usage_rules_INDEX) run BEFORE the git commit (codegen-scaffold do_create):

1. Stack-specific scaffold.sh completes file writes
2. `run_integrate_stage` renders cross-stack files from templates
3. Git commit runs after integrate-stage (single commit point for both stacks)
4. Atomic mv from temp parent to final location

This eliminates the dirty-tree race: integrate-stage files rendered AFTER the commit → `git status --porcelain` non-empty → build failure.

## Elixir Seam Threading — Preserving Test-Override Capacity

When adding a new parameter to an Elixir function that is called in a default closure but tested via seam overrides, thread the parameter into the closure BINDING, not into the seam signature. Example:

The `OrchestrationLoop.invoke_role/4` function has a `/6` `codegen_call_fn` seam. When the Elixir loop needs to pass a new `agent` parameter to `default_codegen_call`, the loop adds a trailing `:agent` param to `default_codegen_call/8` → `/9`. The loop's default closure `:369-372` binds `role` (already in scope in `invoke_role`) into the call to `default_codegen_call`, passing `role` as the new ninth argument. Tests that override `codegen_call_fn` via a seam do NOT change signature — they still receive /6 args (`cwd, model, effort, system_prompt_path, allowed_tools, prompt`). The loop's default closure adapts: it builds the /9 call internally without forcing test overrides to match.

**Benefits**: 
- Zero churn to every test override of `codegen_call_fn` (can be dozens across the test suite)
- The parameter is added at the call site (the loop) where it's known, not at the seam boundary
- The seam stays a stable interface for tests

**When NOT to use this pattern**: When the parameter is genuinely part of the seam contract (i.e., every override MUST know about it), thread it into the seam signature and update all test overrides. Use this pattern only when the loop-specific code (the default closure) should own the new parameter and tests don't need to override it.

## RoleResolver Shape Changes and Sibling Test Ripple

When a public function in Elixir changes its return type (e.g., `resolve_role/2,3` returning `{String.t(), String.t()}` instead of a 4-tuple), the shape change ripples to test files that are NOT explicitly listed in the edit scope. Example: a pitch naming `orchestration_loop_test.exs` but NOT `role_resolver_test.exs` still requires the sibling to be updated because `resolve_role`'s public contract changed.

**Fix**: Before editing the primary target file, grep for ALL references to the function across `test_harness/test/` with keywords like `resolve_fn`, `resolve_role`, `codegen_call_fn` + the module name. A narrower grep scoped only to the plan's file list will miss sibling test files that stub the same functions. Update all test overrides/stubs in the same pass.

## Trigger Keywords

make install, make test, make test-stacks, CI/CD, Makefile, contribution, README, env vars, harness-parity, launcher tests, Makefile for t in list, dev loop, tech stack, coding conventions, multi-repo ordering, context codegen platform, seam threading, RoleResolver, function shape change

→ See `context/pitfalls.md` for codegen-infra pitfalls and bash gotchas.

## Trigger Keywords

make install, make test, make test-stacks, CI/CD, Makefile, contribution, README, env vars, harness-parity, launcher tests, Makefile for t in list, dev loop, tech stack, coding conventions, multi-repo ordering, context codegen platform
