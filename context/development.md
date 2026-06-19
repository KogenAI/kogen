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
| `ANTHROPIC_API_KEY`  | Claude/Pi API key            | Required; not in `.env`                                                                                                                                                                                                                                                    |
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
- **Bash module name derivation**: Use `python3` one-liner for slug→CamelCase; pure-sed BRE is fragile across BSD/GNU + bash 3.2 case-fold gaps. Reference: `scaffold.sh` line 81.
- **Finding byte-identical lines across two files**: `comm -12 <(sort file1) <(sort file2)` — intersection idiom. Primary use: detecting harness header drift; used by `tools-header-no-dup_test.sh`.
- **Anchoring to exact text, not line numbers**: Always anchor Edits to exact phrases (never line numbers); they drift as files evolve. For ordered lists, anchor to the TEXT of the current first item (not the section header). For session logs, anchor to text DIRECTLY under the intended H2 header to avoid inserting into a sibling section.
- **Parallel Read then parallel Edits**: For independent single-line insertions into different files, Read all targets in parallel first to confirm anchors, then execute all Edits in parallel.
- **Scaffold.sh Phase pattern for new directories**: Canonical model is Phase 3 (`priv/plts` + `.keep` file): `mkdir -p` + `touch .gitkeep` + echo status message.
- **Python**: stdlib only in generator scripts — no third-party deps.
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

## Common Pitfalls

- **Split extraction: verify load-bearing, not meta** — Extractors pull EOF by default. Stop boundary BEFORE trailing meta (e.g., `## Update When Changing`). Verify last H2 is terminal cluster, not footer. Use grep `^## ` to detect boundaries.
- **`make install` registry/settings.json parity** — add registry.yaml entry, add .sh file, run `hook_registrations.py --output-settings` BEFORE `make install` to regenerate settings.json. Running `make install` first causes hook-parity diff to fail (generator creates fresh settings.json that differs from committed version).
- **Bash JSON: use `jq -n --arg`** — `printf` + single quotes produces invalid `"`; use jq for safe assembly.
- **Bash heredoc keeps loop state** — `while <<EOF` not `|` pipe (subshells lose vars).
- **TS `execFileSync` args: array not string** — `execFileSync('git', ['commit', '-m', 'msg'])`.
- **TS `.trim()` loses trailing-newline** — split `git()`: `gitLog()` (trim), `gitBlob()` (no trim, null on error).
- **TS exec error sentinel** — use null for non-zero, "" for zero-exit-empty.
- **TS `mkdtempSync` unused** — remove if memory-only comparison.
- **Bash set-never-read** — remove on refactor.
- **`manifest_regenerate_prompts` file check** — new prompt-source `.txt` files must exist before `make install` (tools-header, prompt bodies). Gate's install round-trip catches missing files.
- **yq binary must be mikefarah, not python-yq** — wrong binary causes silent manifest parsing errors.
- **`npm install` at codegen root required** — absent → hooks emit INCONCLUSIVE.
- **`make install` required after rule/template change** — regenerates baked prompts.
- **Cross-stack guard after adjacent-include edits** — When editing rule files or `.md.j2` templates adjacent to shared-fragment `{% include %}` directives, verify zero drift in the shared fragment itself. Pattern: `git diff --name-only | grep _orch-behavioral` confirms `shared/apps/_orch-behavioral.md.j2` untouched (applies to all shared cross-stack includes). Run after every adjacent edit to catch accidental cross-stack pollution.
- **Chromium binary absence is fail-closed on static boxes** — gate BLOCKS when missing.
- **`mise trust` runs unconditionally on install** — no interactive prompt.
- **Do not run `npm install` at repo root for Pi extensions** — each extension has its own node_modules; only root install is managed by install.sh
- **Hook test failures are not ExUnit** — `make test` runs bash tests + hermetic ExUnit; they are separate suites
- **Hook test runner summary mismatch — `run-tests.sh` blind spot** — `run_one` checks `grep -qE "failed [1-9]"` but format is `"<digit> failed"`. Pattern never matches. Failures still trigger at execution time; exit code correct. Not a gate blocker.
- **`make test-stacks` must never regress to bare `mix test`** — gate uses `mix test --only slow`; bare `mix test` silently runs ZERO stack tests and exits 0 (fake-green). Always tag LLM-driven tests with `:slow`.
- **Test source change requires migrating ALL dependent cases (Rule J)** — When a fixture's input source changes, all test cases using the old path must migrate; leaving them asserts the OLD spec (dead code). Non-retryable/allow-only cases producing the same verdict regardless can stay.
- **`shared/scaffold/static/scaffold_test.sh` is wired into `make test`** — new bash test cases run automatically (Makefile line 131 includes). No Makefile edits needed; test summary updates via inline helpers.
- **config.yaml structure: anchor to block shape, not value** — Multiple blocks may share the same leaf value (e.g., `model: opus` in both `harness.shape.claude` and `roles.shape`). Edit's `old_string` MUST include surrounding context (full multi-line block) to avoid landing in the wrong block. Use `yq '.roles.shape.model' config.yaml` to verify post-change.
- **Pitch line numbers are estimates** — developer MUST Read the actual file to locate exact anchor text before Editing. Pitch approximations drift as file history accumulates. Example: pitch said `codegen-scaffold:317-322` but actual `ci:` injection was `:324-329`; always anchor to exact text.
- **Example blocks in reference documents may also carry routing targets** — when bulk-repathing in a reference/mapping file, check inline example blocks and callouts too. After `old_string`/`new_string` replacements, grep old path in the file; all hits must be either (a) repathed or (b) inside warning/denial prose.
- **Phoenix-colocated esbuild requires compile-before-build chain** — `phoenix-colocated` import in `app.js` only exists after `mix compile`; `assets.build` + `assets.deploy` aliases must include `"compile"` prefix.
- **`CODEGEN_DIR` must be absolute** — relative paths break symlink resolution in launchers
- **Session log filename format must include `_HHMMSS`** — non-canonical forms (e.g., `YYYYMMDD-slug.md`) are blocked by reviewer-guard and dev-gate hooks at Edit time
- **Transcript lag in print-mode builds** — on-disk JSONL may lag the stream. `session_log_from_transcript()` implements build-scoped fallback. See `context/hook-authoring-patterns.md` § Transcript Lag & Discovery Pattern.
- **Makefile recipes run under `/bin/sh`, not bash** — process substitution fails. Use pipeline patterns instead of bash-specific syntax.
- **Makefile doctor pattern for binary presence** — `executablePath()` returns a path even when binary NOT downloaded; must test `fs.existsSync()` to confirm download completion.
- **Build mode uses baked tools, shape/ops/debug modes use runtime config** — `build-tools.txt` is baked at `make install` time. Shape/ops/debug launchers invoke `load-role.sh` to read `config.yaml` at invocation time. Planner pitch claims about config.yaml changes must be verified against working tree before trust.
- **Flaky tests often indicate state leakage, not async timing** — investigate persistent state first (counter files, temp dirs, session IDs). Counter files from `runHook()` (e.g., `claude-autoship-guard-<sessionId>.count`) persist across test runs; add explicit cleanup in `afterEach`.
- **Test isolation scoping** — TypeScript: capture streams at test-body (not `beforeEach`/`afterEach`); restore in both paths. Bash: trap-clean temp dirs; PATH-stub binaries need per-line `PATH="$BIN_DIR:$PATH"`. Fixture layering: innermost clean → intermediate symlink → outermost dirty.
- **Pi test essentials** — Disk-read tests must create real temp files at test-specified paths. `npm run build` BEFORE `npm test` (tests run on `dist/`, not `src/`). Verify passing by grepping runner output for `fail 0` — individual test names may contain "FAIL:" as a description, not a failure indicator.
- **Gate hook command switch requires all build-exercising fixtures to match** — When a gate hook's build invocation changes (e.g., `mise exec -- npm run build` → `make ci`), every fixture reaching the build step must be updated; fixtures short-circuiting before (Hugo skip, missing package.json) need no change. Add a hermetic `Makefile` with `ci:` recipe (`@true`/`exit 1`) per fixture. Makefile recipe lines MUST use hard tabs — `printf 'ci:\n\t@true\n'` works; spaces silently break `make`.
- **`chmod 000` is a no-op under root** — Tests making files unreadable via `chmod 000` must not assume restriction holds under root.
- **Clean-tree gate enforces one-commit-per-cycle rule** — `build-no-success-before-commit.sh` blocks BUILD_RESULT: success if `git status --porcelain` non-empty. All dirty/untracked files must be gitignored or committed.
- **Rule-file includes are static at install time, not runtime** — fix requires THREE steps: (1) edit the rule file, (2) add `{% include %}` directive to the role-def template, (3) run `make install`. Plan discovery without implementation produces a dry audit — no live change.
- **`make test` does NOT run `make install`** — rule-prose / template edits are baked at install time. Workflow: edit → `make install` → `make test`. Skipping install leaves baked prompts stale.
- **Shape prompt two-layer architecture: inline-probe vs readiness-check** — The shape system prompt layers two independent gates: (1) inline-probe (`_probing.txt`, first gate at claim-introduction) runs discipline checks on the spot (e.g., sweeps must target committed state, not dirty tree; sub-agent findings are unverified leads until re-probed); (2) readiness-check (`shape.txt`, final backstop before promotion) runs structural-scan and completeness gating (e.g., sweep-class pitches must list enumerated-vocabulary coverage and producer/verifier reconciliation). New shape rules MUST be placed by gate-phase — inline-probe discipline in `_probing.txt`, readiness gating in `shape.txt` — to avoid duplication and ensure each clause lives in its architectural home. The `/ready` command inherits `_probing.txt` automatically via `{% include %}`; only `shape.txt`-only rules need explicit `ready.md.j2` body edits.
- **`make install` re-pads rule-file markdown tables** — table column widths auto-align via prettier; separate `make format` optional.
- **When a plan specifies dynamic-enumeration engine, verify implementation does it** — Hard-coding paths contradicts the design guarantee. Always inspect the implementation; description alone is not evidence of execution.
- **prompt-content-parity_test.sh sentinel sync** — Load-bearing text changes → sentinels MUST match exactly (`grep -qF`). Sentinels target SOURCE files, not baked paths. Runner calls `make install` automatically. Dual sources: one SENTINEL var, assert in both baked prompts via separate `assert_contains` calls. Pre-validation: grep `prompt-content-parity_test.sh` for source-file names; zero hits → no sync needed. Retargeting: when content moves verbatim, retarget file-path arg only — sentinel strings stay unchanged.
- **`PROJECT_CONTEXT.md` blocks the Read tool** — `subagent-read-discipline.sh` gate denies Read to non-planner roles. Edit via Bash with the mktemp/cmp/mv pattern.
- **Scoped removal of multi-category tokens** — tokens may appear in multiple independent categories; removal pitches must scope to one.
- **`git status --porcelain` on fresh fixtures requires explicit commit** — `git init` + untracked files = dirty. Run `git init` + `git add -A` + `git commit` to establish a clean-tree baseline, then create stray files for the dirty case.
- **Pi test fixtures for gate-result checks must commit gate-result.json** — JSON file must be committed or its directory must be in .gitignore. Otherwise dirty-tree check fires before the intended new check.
- **`dev-no-self-gate` blocks after 3 invocations per session** — developer role can invoke own gate at most 3 times. Run targeted tests (bash script directly, or npm test in extension dir) rather than full gate to verify before triggering gate slots.
- **Recovering deleted scripts** — strip dead deps first, repoint callsites to current primitives (`codegen-call`, `$CODEGEN_DIR` from `BASH_SOURCE`).
- **Single variable binding propagates to multiple interpolation sites** — when a Bash function assigns a versioned URL at a single point, that binding threads into all later interpolation sites. Pinning the variable at the assignment site updates all interpolations with no further edits.
- **External contract claims use OR, not AND** — execute repo code path OR exercise contract directly (curl/WebFetch); alternatives, not cumulative.
- **External probe spread: 4 rules** — name axis, probe both ends, single-sample inconclusive, failure mandatory.
- **Semantic equivalence vs structural identity in prompt-body sibling files** — verify semantic equivalence of all rules, NOT literal step-count parity. Compression preserving all semantic rules is correct mirroring.
- **Planner-guard blocks Read on rule files** — use `Grep -C` for anchors; cite in pitch, developer confirms via Read.
- **Context files carry a 40 KB advisory cap** — `context/*.md` files have 40,960-byte limit. Compress or split when near cap.
- **Exit-code capture under `set -u`** — `local rc; raw=$(cmd) || rc=$?; rc=${rc:-0}`. `rc` unset on success. Distinguishes broken-cmd (empty) from `INCONCLUSIVE:*` verdicts.
- **Makefile `@for` recipes are POSIX-only** — Accumulator: `fail=0; ... || fail=1; exit "$$fail"`.
- **Pitch byte targets grow stale** — Planner re-measures `wc -c` at plan time, not pitch time; stale budgets cause gate failures.
- **Heredoc piping with `>` redirects trips planner-guard** — write script to temp, run with redirect outside.
- **Prettier 3.8 re-pads wide-cell markdown tables** — long cell values in tables are re-padded by prettier. Guard byte-capped context files via `.prettierignore`: add files BEFORE `make format`.
- **Dual-read unset tests unset BOTH vars** — `env -u NEW -u OLD bash "$HOOK"` (single unset leaves fallback active).
- **`replace_all` composite keys + test cleanup both old/new** — `replace_all: true` on `"user_app_build"` does NOT match `"claude/user_app_build"` variants; use separate passes per prefix. Pi test cleanup must delete both old and new env var names; single delete leaves fallback active.
- **Removing a config.yaml role breaks slow ExUnit tests** — `@moduletag :slow` tests excluded from `make test` (`--exclude slow`) but run in `make test-stacks` (`--only slow`). Deleting a role → silently passes `make test`, fails `make test-stacks` with `ERROR: roles.<role>.model missing/empty`. Survey both gates; update all `:slow` tests to valid roles before commit.
- **Curator byte cap enforcement** — curator-edited `context/*.md` exceeding 40,960 B gets reverted. Before finishing, check `wc -c`; if over, compress bullets or split to new file.
- **Grep recipe single-level vs recursive on hook catalogs** — `harnesses/claude/hooks/*.sh` (single-level glob) misses `lib/hooks-lib.sh` subdir. For complete enumeration use `harnesses/claude/hooks/**/*.sh` or `harnesses/claude/hooks/` recursive. Single-level approximations like "~24 hooks" absorb the library gap; if exact per-hook list is needed, widen the glob.
- **Enforcement subsection placement in rule files** — when adding a new subsection to a rule file with existing structure (e.g., `## Ownership`), place it as a new H2 section at the same level rather than embedding mid-section. Cleaner structure, avoids disrupting prose flow. Accompanied by a pointer-only reference in dependent docs (no duplication).
- **Rule-file line caps are STYLE_GUIDE advisory only** — `_core/` rule files have a <50-line advisory in STYLE_GUIDE; `roles/` and `stacks/` have <150-line advisory. No hook enforces rule-file line count. Only `context/*.md` byte cap (40,960 B) is hook-enforced via `context-file-size-gate.sh`. Rule-file overage is acceptable if unavoidable; byte-cap overage blocks commit.
- **`process_template.py` include/if ordering** — `process_includes_recursively` runs AFTER if-stripping → `{% if tool %}` blocks inside fragments survive un-stripped → both branches concatenate (BROKEN). Fix: move include call to TOP of `_strip_template_blocks`, before if-stripping. Verify via `make test-generator` + `make test`.
- **Fragment whitespace and byte-identity** — `resolve_include` appends `\n` only when absent. Template whitespace around `{% include %}` (not fragment's internal `\n`) determines output blank lines. Byte-identity requires exact trailing-newline match when extracting.
- **Non-contiguous shared regions need separate fragments** — Verify regions are contiguous in BOTH templates BEFORE design. Non-contiguous regions → separate fragments (one per region with own `{% include %}`), not single-file-multiple-includes (→ duplication).
- **`make test-stacks` pre-gate checklist** — Run `make doctor` (Chromium + ajv), verify `ANTHROPIC_API_KEY` set, verify `command -v pi`. Bucket every failure via 4-bucket protocol before source edits → `context/test-harness.md § Flake Triage Protocol`.
- **`make test` auto-discovers bash tests in `test_harness/install/`** — New `*_test.sh` files under that dir run automatically via `run-tests.sh` (which greps for `N passed, N failed` footer). No Makefile edits needed. Structural-grep tests assert spec (masking patterns gone, fail-loud patterns present), not implementation details. Footer format is critical: `echo "$passed passed, $failed failed"` must match the runner's grep pattern exactly.
- **install.sh fatal-exit composition** — New guards compose with existing fail-fast chains (root-npm install :196, yq gate :223, manifest-lib guard :231–235). All fatal exits extend the linear fail-chain without reordering. Non-fatal stderr dumps (e.g., prettier formatting errors) are observed-only; don't affect `✅ Installation complete`.
- **Structural grep sentinels with literal quotes** — Anchor to stable substrings (variable names like `_pi_ext_install_failed`, icons like `❌`, unique ops like `cat "$_prettier_err"`), not full source lines. For sentinels with double-quotes, use `grep -F` (fixed-string mode). Single-quote shell condition strings: `'! grep -qF "pattern with \"quotes\"" file'` prevents shell interpretation.
- **Relative symlinks survive relocation only if computed against FINAL location** — In a create-flow that builds in temp dir then `mv`s to final, relative symlinks MUST be computed against the final dir. A relpath against the temp path carries one extra `../` and dangles post-mv. Solution: thread `link_base_dir` to `run_integrate_stage()` from create callsite, passing final `$target_dir`. Integrate-path defaults `link_base_dir` to `$CWD`. Test: `readlink` returns relative (no `/` prefix) and `[ -e ]` dereferences correctly.
- **Masked pipe errors reveal fixture gaps** — When a pipe with `| sed` or similar filtering masks real errors in subprocess output (e.g., `npm install 2>&1 | sed 's/^/      /'`), removing the mask surfaces hidden failures. A pre-existing test fixture (e.g., missing `MISE_STATE_DIR` in HOME override) may be the root cause. Investigate and fix the fixture, don't ignore the newly-visible error. This is a feature, not a regression.

## Deployment / Distribution

Codegen runs on servers too — production/staging Linux hosts and the Hetzner dashboard box all run codegen, in addition to operator Macs. Distribution = `make install` on each machine; each derives its root from `BASH_SOURCE`, never hardcoded. CI validates that scaffold output compiles and hook tests pass. PRs require both `make test` and `make test-stacks` green before merge. See `context/deployment-topology.md`.

## Bash Patterns & Pitfalls (Codegen-Infra)

- **Scaffold global-read convention** — `run_integrate_stage()` reads scaffold parameters as GLOBALS (`STACK`, `SLUG`, `RESTART_RPC_CMD`, etc.), not function parameters. New flags assigned in the shared arg-parse loop; NO parameter threading. One arg-parse pass; dual callsites (create + integrate) both see the globals.
- **COMMON_FLAGS array** — dispatch scripts use a shared flags array for mode-invariant vs mode-specific flags. Build array once, splice into both exec paths. Under `set -u`, guard VALUE expansions with `if [[ ${#arr[@]} -gt 0 ]]; then` — `${arr[@]+"${arr[@]}"}` is rejected by shfmt; use explicit length-guards.
- **Shared fns called from multiple harnesses** — thread a `mode` parameter to gate harness-specific behavior. Example: `render-check.js` `runChecks(url, timeoutMs, mode)` gates content-region check on `if (mode === "phoenix")`.
- **`local` keyword under `set -u`** — fails in `if/elif` at script scope. Use bare assignment. Function scope OK. Reset loop-branch locals at top: `local repo_url="" tree_ref=""`.
- **Portable sed** — `sed -i ''` (macOS BSD) NOT portable to GNU sed (Linux). Use temp-file rewrite or `sed -i.bak 's/old/new/' file && rm -f *.bak` (non-empty extension works on both).
- **Bash 3.2 compatibility** — macOS system bash is 3.2: no `declare -A` (use indexed array + awk filter), no `wait -n` (use `wait "$pid"` loop). `git -C <nonexistent-dir>` exits 128 — walk `dirname` to first existing ancestor; re-canonicalise via `hooks_realpath` (macOS `/tmp`→`/private/tmp` breaks prefix match).
- **IFS multi-char join** — `IFS=', '; echo "${arr[*]}"` uses only first char. Use `printf '%s, ' "${arr[@]}" | sed 's/, $//'` instead.
- **`cut` mixed delimiters** — `cut -d: -f2` captures tail. Chain delimiters: `cut -d: -f2 | cut -d'|' -f1`.
- **Heredoc expansion** — unquoted `<<EOF` expands variables; `<<'EOF'` does not.
- **Grep footguns** — `-v` deletes lines; process BEFORE drop. BRE `\(` = GROUP; use `-F` for literals. Avoid backslash collapse; use `-qF`.
- **Shell test binary stubbing** — fake_bin_dir: symlink standard tools, omit target binary, filter `$PATH`. Use `command -v` (not `which`) — builtin, bash 3.2+. **Gotcha**: `export -f function_name` does NOT propagate to nested `bash "$HOOK"` subprocesses. Use PATH-stub pattern (real fake-binary on `$PATH`) — inherited by all subprocesses. For git stub: `PATH="$BIN_DIR:$PATH" bash "$HOOK"`, not `export -f git`.
- **Hook stub isolation for sourced files** — Pre-sourcing a stub doesn't work — hook's own source call overrides it. Instead: create per-test `CODEGEN_DIR` subdir, write stub there, invoke with `CODEGEN_DIR="$TMP_ROOT/resource_manager_tN" bash "$HOOK"`. Each test needs its own isolated dir.
- **jq null extraction in hook payloads** — `jq -r '.field'` on JSON null emits `"null"` (not empty). Always use `jq -r '.field // empty'` for optional fields; bare `.field` causes git/mkdir to treat `"null"` as a literal path argument.
- **Conditional final statements** — `&&` as last statement flips exit code. Use `if/then/fi` instead.
- **VERBOSE gating** — `if/fi` doesn't flip exit code; `&&` one-liner does.
- **Post-condition assertions in mutations** — validate preconditions (file exists, anchor present) and postconditions (expected lines added, placeholders resolved). `eex_render.sh` should fail on unresolved `<%= ... %>` placeholders.
- **Cleanup wrappers & exit code propagation** — `bash -c "cmd; rm -rf $TMP"` loses the inner exit code if cleanup succeeds. Pattern: `RESULT=0; inner_cmd || RESULT=$?; cleanup_code; exit $RESULT`.
- **Fail-closed refute in tests** — to prove a script aborts BEFORE an irreversible action, use a shimmed subprocess marker: stub the irreversible command to record if called, then `refute` the marker was set.
- **Advisory health checks** — embed advisory output in same SSH output blob; parse verdict gate by reading ONLY gate-specific labels. Never include advisory section in `if [ ... ]` gate logic.
- **Multi-prompt headless gates** — one independent env var per interactive prompt. Example: `DEPLOY_AUTO=1` skips confirm; `DEPLOY_AUTO_ROLLBACK=1` (separate) skips rollback prompt.
- **Operator toggles vs app runtime config** — `DEPLOY_AUTO=1`, `RELEASE_DAY_OVERRIDE=1`, `codegen-scaffold --recipe-source=<path>` are operator toggles → NOT in `.env.sample`. Toggles go in script header comments; app env vars go in `.env.sample`. Toggles control harness/build; env vars control app runtime.
- **Deriving state properties from ordered lists** — Derive computed property (e.g., "terminal") from the list's LAST element: `for w in $CYCLE_STATE_ORDER; do last="$w"; done; [ "$1" = "$last" ]` — not hard-coded. Adding a new terminal state shifts the property automatically. Callers test returned values (`[ -n "$result" ]`); helpers return empty string on unmatched input (`set -u`-safe).
