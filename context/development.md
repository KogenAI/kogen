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

**OCG\_\* platform-injected variable convention**: Consumed-only variables (injected by build orchestrator, never set by codegen) follow naming pattern `OCG_<CATEGORY>_<PURPOSE>`. Placement in `.env.sample` and `.env.prod.sample` is consistent: group all `OCG_*` vars under a single comment block describing their purpose (e.g., "Consumer-supplied build-worker confinement roots"). When adding a new consumed OCG var, append it to the existing block, not in isolation — maintains operator discoverability and follows existing convention from `OCG_APPS_ROOT`, `OCG_PHOENIX_SEED_DIR`, and `OCG_USER_FILES_DIR`.

## Coding Conventions

- **Bash**: `set -euo pipefail` in all scripts; `content_stable_cp` is defined in `install.sh` (not `utils.sh`) for idempotent file copies; `utils.sh` provides only `OCG_CMD`
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
- **TypeScript**: strict mode; each extension self-contained with own `package.json`. **Test isolation under parallel runners**: capture stderr/stdout at test-body scope, not `beforeEach`/`afterEach` — avoids cross-test pollution. Restore streams in finally block on both pass and throw paths. Example:

  ```typescript
  it("verifies error message on transient error", () => {
    process.env.LAST_ASSISTANT_MESSAGE = "Stream idle timeout";
    const originalStderr = process.stderr.write;
    let stderrOutput = "";
    process.stderr.write = (str: any) => {
      stderrOutput += str;
      return true;
    };

    try {
      handler({ reason: "quit" } as any);
      assert(stderrOutput.includes("[pi-enforcement]"));
    } finally {
      process.stderr.write = originalStderr;
      delete process.env.LAST_ASSISTANT_MESSAGE;
    }
  });
  ```

  See `harnesses/pi/pi-extensions/enforcement/src/hooks/__tests__/stop-resume.test.ts` for working example. **Regex anchors**: JavaScript does not support `\z`; use string-split extraction. **Markdown parsing**: prefer `split("## ")` + slice over regex for section body extraction. **TS try/catch fail-open**: wrap entire multi-step resolution chain in one `try/catch`; any step throwing is caught uniformly → exit 0 (allow). No per-step null guards needed. Differs from bash where guards must be chained explicitly. **Byte-count parity Bash↔TS**: When a Bash hook measures byte size via `wc -c` (counting bytes), the Pi twin MUST use `Buffer.byteLength(blob, "utf8")` or `Buffer.byteLength(blob)` with `encoding: "buffer"` (counting bytes, not `string.length` which counts UTF-16 code units). Multi-byte UTF-8 characters produce silent divergence under `string.length` — use only buffer-based counting in TS hooks. Bash `wc -c | tr -d ' '` and TS `Buffer.byteLength` are byte-count equivalents.

- **Commit messages**: why-focused, delegated to committer subagent — never written directly by orchestrator
- **Session log body placement**: When writing subagent retrospectives or test results to a session log via Edit, ensure the insertion anchors to text DIRECTLY UNDER the intended section header (e.g., `## developer-phoenix-backend Section`), never to text that appears below a SIBLING section header. Anchoring to text below a sibling section causes the new content to insert into the wrong section. Pattern: Read the log file, locate the exact text immediately following the target `## ` header, use that text as the anchor in `old_string`. After each Edit, visually verify the insertion landed in the correct section — misplaced content silently breaks hook parsing (e.g., retrospective blocks under dev-gate section are missed by curator curation).

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
- **`make install` registry/settings.json parity** — when adding a `kind: registration` entry in `shared/enforcement/registry.yaml`, BOTH the registry.yaml entry AND the committed `harnesses/claude/claude-code-settings.json` entry must be present before parity checks pass. Workflow: (1) add registry.yaml entry, (2) add .sh file with HOOK-MANIFEST header, (3) run `hook_registrations.py --output-settings` to regenerate settings.json BEFORE calling `make install` (not after), (4) run `make install` (hook-parity check will PASS since settings.json is now in sync), (5) commit both changed files (.sh, registry.yaml, settings.json) together. Running `make install` before regenerating settings.json causes hook-parity diff to fail — the generator creates a fresh settings.json that differs from the committed version.
- **`make install` gated on python3, node, yq-mikefarah** — `apt install yq` installs python-yq (incompatible, silently wrong manifest parsing) — use mikefarah/yq binary instead.
- **`npm install` at codegen root required** — root `node_modules/` (ajv, playwright, prettier) must exist for schema-validate.js/render-check.js; absent → hooks emit INCONCLUSIVE. install.sh runs automatically.
- **`make install` required after rule/template change** — agents see old baked prompts otherwise.
- **Chromium binary absence is fail-closed on static boxes** — Static-site build gate BLOCKS (not skips) when Chromium missing. Benchmark screenshot capture tolerates missing Chromium; the gate does not.
- **`mise trust` runs unconditionally on install** — enforcement `.mise.toml` is now trusted without `OCG_NONINTERACTIVE` gate; interactive installs no longer hang on trust prompt.
- **Do not run `npm install` at repo root for Pi extensions** — each extension has its own node_modules; only root install is managed by install.sh
- **Hook test failures are not ExUnit** — `make test` runs bash tests + hermetic ExUnit; they are separate suites
- **Hook test runner summary pattern mismatch — `run-tests.sh` blind spot** — `run_one` checks `grep -qE "failed [1-9]"` but output format is `"<digit> failed"` (number before word). Pattern never matches; failures with 1+ fails pass silently at summary level. Mitigation: failures still trigger via `assert_eq` at execution time; `make test` exit code is correct. Not a gate blocker, but explains confusing hook-test debug output.
- **`make test-stacks` must never regress to bare `mix test`** — gate uses `mix test --only slow`; bare `mix test` silently runs ZERO stack tests and exits 0 (fake-green). Always tag LLM-driven tests with `:slow`.
- **`shared/scaffold/static/scaffold_test.sh` is wired into `make test` — no Makefile edit needed** — new bash test cases in `scaffold_test.sh` run on the `make test` gate automatically (Makefile line 131 includes the file). Any new case assertion runs without modifying Makefile; test summary updates via inline helper calls (`pass=$((pass + 1))`, etc.).
- **config.yaml structure: anchor to block shape, not value** — When editing config.yaml, two or more blocks may contain the same leaf value (e.g., `model: opus` appears in both `harness.shape.claude` at line 89 and `roles.shape` at line 164). The dead `harness.shape.claude` block is single-line: `{ model: opus, effort: high }`; the live `roles.shape` block spans 4 lines. Edit's `old_string` MUST include surrounding context (full 4-line block for roles.shape) to avoid landing in the dead block. Use `yq '.roles.shape.model' config.yaml` to verify which block was edited post-change.
- **Pitch line numbers are estimates** — developer MUST Read the actual file to locate exact anchor text before Editing. Pitch approximations drift as file history accumulates.
- **Example blocks in reference documents may also carry routing targets** — when bulk-repathing or correcting paths in a reference/mapping file (e.g., `context/curator-routing.md`), check that inline example blocks, case studies, or callouts within the section body also get repathed. Pitfalls: an Ambiguous Cases example might cite `shared/rules/_core/hooks.md` expecting rewrite to `codegen/rules/_core/hooks.md`; catching this requires a final grep of the entire edited section, not just the main bullets. Remedy: after `old_string`/`new_string` replacements, run a search for the old path pattern in the modified file and confirm all hits are either (a) repathed or (b) inside warning/denial prose ("never edit raw...").
- **Phoenix-colocated esbuild requires compile-before-build chain** — `phoenix-colocated` import in `app.js` only exists after `mix compile`; `assets.build` + `assets.deploy` aliases must include `"compile"` prefix.
- **`CODEGEN_DIR` must be absolute** — relative paths break symlink resolution in launchers
- **Session log filename format must include `_HHMMSS`** — non-canonical forms (e.g., `YYYYMMDD-slug.md`) are blocked by reviewer-guard and dev-gate hooks at Edit time
- **Transcript lag in print-mode builds** — on-disk JSONL may lag the live stream. `session_log_from_transcript()` implements a build-scoped fallback. See `context/hook-authoring-patterns.md` § Transcript Lag & Discovery Pattern.
- **Makefile recipes run under `/bin/sh`, not bash** — process substitution fails. Use pipeline patterns instead of bash-specific syntax.
- **Makefile doctor pattern for binary presence** — `executablePath()` returns a path even when binary NOT downloaded; must test `fs.existsSync()` to confirm download completion.
- **Build mode uses baked tools, shape/ops/debug modes use runtime config** — `build-tools.txt` is baked at `make install` time. Shape/ops/debug launchers invoke `load-role.sh` to read `config.yaml` at invocation time. Planner pitch claims about config.yaml changes must be verified against working tree before trust.
- **Flaky tests often indicate state leakage, not async timing** — investigate persistent state first (counter files, temp dirs, session IDs). Counter files from `runHook()` (e.g., `claude-autoship-guard-<sessionId>.count`) persist across test runs; add explicit cleanup in `afterEach`.
- **TypeScript test isolation: capture streams at test-body scope** — not in `beforeEach`/`afterEach`. Restore streams in both resolve and reject paths. **Bash test cleanup**: temp files can leak; use `mktemp` + explicit per-call `rm`, or create all under root trap-cleaned dir. **Bash test PATH stubs**: When stubbing a PATH binary (e.g., sleep stub into `$TMP_DIR`), split cleanup into (a) `reset_counters()` clearing ONLY state files pre-test, and (b) `teardown()` with `rm -rf "$TMP_DIR"` in `trap EXIT`. Order: stub creation → trap → pre-test reset. Pre-test reset deleting `$TMP_DIR` kills the stub before tests run. Inline `env ... bash "$GUARD"` calls outside helpers don't inherit parent env — add explicit `PATH="$TMP_DIR:$PATH"` to each line. **Layered fixture setup**: build fixtures innermost (repo clean) → intermediate (symlink committed) → outermost (dirty state), then assert check fires.
- **Node 22+ test concurrency and process-global state** — Node 22+ runs `describe()` children concurrently. When tests use `process.chdir()`, add `{ concurrency: 1 }` to `describe()`. **Pi test disk-read patterns**: hook tests that call `fs.existsSync()` or `fs.readFileSync()` on a specific path must create a real temp file at that exact path. **Pi test helper extension**: extend helpers with optional 4th params spread into tool input — existing callers unaffected. **npm run build precedence** (MANDATORY): Pi tests run against `dist/` (compiled output), not `src/`. Always `npm run build` BEFORE `npm test` after ANY `.ts` change — stale `dist/` causes assertions to run against old compiled code with no error or warning. **Pi test runner output**: `node:test` runner emits status lines like `ℹ tests N / ℹ pass N / ℹ fail 0` at the tail. Verify all passing by grepping for `fail 0` (exact string); note that individual test names may contain `FAIL:` as part of their description (naming a failure scenario), which is NOT a test runner failure. Only the final `fail N` metric indicates actual test failures.
- **Gate hook command switch requires all build-exercising fixtures to match** — When a gate hook's build invocation changes (e.g., `mise exec -- npm run build` → `make ci`), every test fixture that exercises the build path must be updated to match. Fixtures that short-circuit before the build step (Hugo skip, missing package.json) need no change. Add a hermetic `Makefile` with a `ci:` recipe (`@true` for pass, `exit 1` for fail) to each fixture that reaches the build step. Tab caveat: Makefile recipe lines MUST use hard tabs (not spaces) — `printf 'ci:\n\t@true\n'` works; indenting with spaces silently breaks `make`.
- **`chmod 000` is a no-op under root** — Tests making files unreadable via `chmod 000` must not assume restriction holds under root.
- **Clean-tree gate enforces one-commit-per-cycle rule** — `build-no-success-before-commit.sh` blocks BUILD_RESULT: success if `git status --porcelain` non-empty. All dirty/untracked files must be gitignored or committed.
- **Rule-file includes are static at install time, not runtime** — fix requires THREE steps: (1) edit the rule file, (2) add `{% include %}` directive to the role-def template, (3) run `make install`. Plan discovery without implementation produces a dry audit — no live change.
- **When a plan specifies dynamic-enumeration engine, verify implementation does it** — Hard-coding paths contradicts the design guarantee. Always inspect the implementation; description alone is not evidence of execution.
- **prompt-content-parity_test.sh sentinel sync** — When a rule file or tools-header source changes load-bearing text, parity-test sentinels MUST match exactly (assertions use `grep -qF`). Sentinels target SOURCE files, not baked paths. **Critical**: tools-header edits require `make install` to bake into `*-build-system-prompt.txt` first — runner calls `make install` automatically. **Dual sources**: one SENTINEL variable, assert in both baked prompts via separate `assert_contains` calls. **Pre-validation**: grep `prompt-content-parity_test.sh` for source-file names; zero hits → no sentinel sync needed. **Retargeting**: when content moves verbatim, retarget the file-path arg only — sentinel strings stay unchanged.
- **`PROJECT_CONTEXT.md` blocks the Read tool** — `subagent-read-discipline.sh` gate denies Read to non-planner roles. Edit via Bash with the mktemp/cmp/mv pattern.
- **Scoped removal of multi-category tokens** — "cursor" appears in three independent categories: Pi TUI text-caret, multi-IDE interop, codegen's own IDE coupling. Removal pitches must scope to one category.
- **`git status --porcelain` on fresh fixtures requires explicit commit** — `git init` + untracked files = dirty. Run `git init` + `git add -A` + `git commit` to establish a clean-tree baseline, then create stray files for the dirty case.
- **Pi test fixtures for gate-result checks must commit gate-result.json** — JSON file must be committed or its directory must be in .gitignore. Otherwise dirty-tree check fires before the intended new check.
- **`dev-no-self-gate` blocks after 3 invocations per session** — developer role can invoke own gate at most 3 times. Run targeted tests (bash script directly, or npm test in extension dir) rather than full gate to verify before triggering gate slots.
- **Recovering and re-wiring deleted scripts** — Strip dead env/config dependencies FIRST (OCG_CONTEXT_DIR blocks, config.sh/utils.sh sources, deprecated --agent flags). Then repoint each callsite to current primitives (`codegen-call`, `$CODEGEN_DIR` from `BASH_SOURCE`).
- **Single variable binding propagates to multiple interpolation sites** — when a Bash function assigns a versioned URL at a single point, that binding threads into all later interpolation sites. Pinning the variable at the assignment site updates all interpolations with no further edits.
- **FORBIDDEN extension for external contracts uses OR, not AND** — "FORBIDDEN: claim external behavior without either (1) executing the repo code path, OR (2) exercising the external contract directly via curl/WebFetch/WebSearch probe." The two techniques are alternatives, not cumulative.
- **Spread technique for external probes requires exactly 4 numbered rules**: (1) name the axis, (2) probe both ends, (3) single-sample is inconclusive, (4) failure case is mandatory.
- **Semantic equivalence vs structural identity in prompt-body sibling files** — verify semantic equivalence of all rules, NOT literal step-count parity. Compression preserving all semantic rules is correct mirroring.
- **Planner-guard blocks Read on certain rule files** — planner cannot Read `testing-liveview.md` + `reviewer.md`. Workaround: use `Grep -C` to capture anchors instead of line numbers, cite anchors in pitch, developer confirms via own Read.
- **Context files carry a 40 KB advisory cap** — `context/*.md` files have ~40,960-byte limit. Compress or split when near cap. Current: `harnesses.md` (939 B over).
- **Exit-code capture under `set -u`** — `local rc; raw=$(cmd) || rc=$?; rc=${rc:-0}`. `rc` unset on success. Distinguishes broken-cmd (empty) from `INCONCLUSIVE:*` verdicts.
- **Makefile `@for` recipes are POSIX-only** — Accumulator: `fail=0; ... || fail=1; exit "$$fail"`.
- **Pitch byte targets grow stale** — Planner re-measures `wc -c` at plan time, not pitch time; stale budgets cause gate failures.
- **Heredoc piping with `>` redirects trips planner-guard** — `>` inside heredoc body detected as suspicious. Workaround: write script to temp file then run it with redirect outside.
- **Prettier 3.8 re-pads wide-cell markdown tables** — long cell values in tables are re-padded by prettier. Guard byte-capped context files via `.prettierignore`: add files BEFORE `make format`.
- **Dual-read unset-case Bash test must unset BOTH preferred and fallback vars** — When testing the "both unset → allow" branch of a dual-read hook (e.g., `${CODEGEN_VAR:-${LEGACY_VAR:-}}`), the test must unset BOTH names: `env -u CODEGEN_VAR -u LEGACY_VAR bash "$HOOK"`. Single unset of only the new name leaves the old-name fallback active, silently passing the unset test without exercising the true "both unset" code path.
- **`replace_all` on composite keys requires separate passes** — `Edit replace_all: true` on a literal string (e.g., `"user_app_build"`) does NOT match composite map keys like `"claude/user_app_build"` or `"pi/user_app_build"`. These require separate `replace_all` passes for each composite prefix. Verify all variants matched by grepping the edited file post-change.
- **Pi test cleanup via delete must cover both old and new names** — When renaming an environment variable across dual-read test sites, cleanup/unset paths (e.g., `beforeEach` or `finally` blocks) must `delete process.env[NEW_NAME]` AND `delete process.env[OLD_NAME]` (add a sibling delete line). Single cleanup of only the new name leaves the old-name fallback active across tests, masking the intended "unset" test case.
- **Removing a config.yaml role breaks slow ExUnit tests** — Tests using `@moduletag :slow` (e.g., `codegen_call_test.exs` passing `role: "bouncer"`) are excluded from `make test` (`--exclude slow`) but run in `make test-stacks` (`--only slow`). Deleting a role from `config.yaml` makes a test that references it silently pass `make test` but fail `make test-stacks` with `ERROR: roles.<role>.model missing/empty`. Both gates must be surveyed when deleting roles. Update all `@moduletag :slow` tests to valid roles before commit.
- **Curator byte cap enforcement** — curator-edited `context/*.md` exceeding 40,960 B gets reverted. Before finishing, check `wc -c`; if over, compress bullets or split to new file.
- **Grep recipe single-level vs recursive on hook catalogs** — `harnesses/claude/hooks/*.sh` (single-level glob) misses `lib/hooks-lib.sh` subdir. For complete enumeration use `harnesses/claude/hooks/**/*.sh` or `harnesses/claude/hooks/` recursive. Single-level approximations like "~24 hooks" absorb the library gap; if exact per-hook list is needed, widen the glob.
- **Enforcement subsection placement in rule files** — when adding a new subsection to a rule file with existing structure (e.g., `## Ownership`), place it as a new H2 section at the same level rather than embedding mid-section. Cleaner structure, avoids disrupting prose flow. Accompanied by a pointer-only reference in dependent docs (no duplication).
- **Rule-file line caps are STYLE_GUIDE advisory only** — `_core/` rule files have a <50-line advisory in STYLE_GUIDE; `roles/` and `stacks/` have <150-line advisory. No hook enforces rule-file line count. Only `context/*.md` byte cap (40,960 B) is hook-enforced via `context-file-size-gate.sh`. Rule-file overage is acceptable if unavoidable; byte-cap overage blocks commit.

## Deployment / Distribution

Codegen runs on servers too — production/staging Linux hosts and the Hetzner dashboard box all run codegen, in addition to operator Macs. Distribution = `make install` on each machine; each derives its root from `BASH_SOURCE`, never hardcoded. CI validates that scaffold output compiles and hook tests pass. PRs require both `make test` and `make test-stacks` green before merge. See `context/deployment-topology.md`.

## Bash Patterns & Pitfalls (Codegen-Infra)

- **Scaffold global-read convention** — `run_integrate_stage()` in `codegen-scaffold` reads scaffold parameters as GLOBALS (e.g., `STACK`, `SLUG`, `RESTART_RPC_CMD` at lines 235, 289, 331), not function parameters. New scaffold flags (e.g., `--recipe-source`) are assigned to globals in the shared arg-parse loop and consumed by `run_integrate_stage` at invocation time — NO parameter threading. This convention simplifies the codebase: one arg-parse pass, dual callsites (create + integrate) both see the globals without param re-threading.
- **COMMON_FLAGS array** — dispatch scripts use a shared flags array for mode-invariant vs mode-specific flags. Build array once, splice into both exec paths. Under `set -u`, guard VALUE expansions with `if [[ ${#arr[@]} -gt 0 ]]; then` — `${arr[@]+"${arr[@]}"}` is rejected by shfmt; use explicit length-guards.
- **Shared fns called from multiple harnesses** — thread a `mode` parameter to gate harness-specific behavior. Example: `render-check.js` `runChecks(url, timeoutMs, mode)` gates content-region check on `if (mode === "phoenix")`.
- **`local` keyword under `set -u`** — fails in `if/elif` at script scope. Use bare assignment. Function scope OK. Reset loop-branch locals at top: `local repo_url="" tree_ref=""`.
- **Portable sed** — `sed -i ''` (macOS BSD) NOT portable to GNU sed (Linux). Use temp-file rewrite or `sed -i.bak 's/old/new/' file && rm -f *.bak` (non-empty extension works on both).
- **Bash 3.2 compatibility** — macOS system bash is 3.2: no `declare -A` (use indexed array + awk filter), no `wait -n` (use `wait "$pid"` loop). Reference: `post-developer-format.sh`, `codegen-document`.
- **IFS multi-char join** — `IFS=', '; echo "${arr[*]}"` uses only first char. Use `printf '%s, ' "${arr[@]}" | sed 's/, $//'` instead.
- **`cut` mixed delimiters** — `cut -d: -f2` captures tail. Chain delimiters: `cut -d: -f2 | cut -d'|' -f1`.
- **Heredoc expansion** — unquoted `<<EOF` expands variables; `<<'EOF'` does not.
- **Grep footguns** — `-v` deletes lines; process BEFORE drop. BRE `\(` = GROUP; use `-F` for literals. Avoid backslash collapse; use `-qF`.
- **Shell test binary stubbing** — fake_bin_dir: symlink standard tools, omit target binary, filter `$PATH`. Use `command -v` (not `which`) — builtin, bash 3.2+.
- **Conditional final statements** — `&&` as last statement flips exit code. Use `if/then/fi` instead.
- **VERBOSE gating** — `if/fi` doesn't flip exit code; `&&` one-liner does.
- **Post-condition assertions in mutations** — validate preconditions (file exists, anchor present) and postconditions (expected lines added, placeholders resolved). `eex_render.sh` should fail on unresolved `<%= ... %>` placeholders.
- **Cleanup wrappers & exit code propagation** — `bash -c "cmd; rm -rf $TMP"` loses the inner exit code if cleanup succeeds. Pattern: `RESULT=0; inner_cmd || RESULT=$?; cleanup_code; exit $RESULT`.
- **Fail-closed refute in tests** — to prove a script aborts BEFORE an irreversible action, use a shimmed subprocess marker: stub the irreversible command to record if called, then `refute` the marker was set.
- **Advisory health checks** — embed advisory output in same SSH output blob; parse verdict gate by reading ONLY gate-specific labels. Never include advisory section in `if [ ... ]` gate logic.
- **Multi-prompt headless gates** — one independent env var per interactive prompt. Example: `DEPLOY_AUTO=1` skips confirm; `DEPLOY_AUTO_ROLLBACK=1` (separate) skips rollback prompt.
- **Operator toggles vs app runtime config** — `DEPLOY_AUTO=1`, `RELEASE_DAY_OVERRIDE=1` etc. belong in script header comments, NOT in `.env.sample`. Similarly, `codegen-scaffold --recipe-source=<path>` is an operator CLI flag (platform-injected, not app runtime) → does NOT go in `.env.sample` / `.env.prod.sample`. The pattern: operator toggles control harness/build behavior; app env vars control app runtime. Script-header documentation suffices for toggles.
- **Deriving state properties from ordered lists** — When a set function derives a computed property from a fixed ordered list (e.g., determining which state is "terminal" in a state machine), derive it from the list's LAST element rather than hard-coding the value: `for w in $CYCLE_STATE_ORDER; do last="$w"; done; [ "$1" = "$last" ]` instead of `[ "$1" = "COMMITTED" ]`. This preserves single-source-of-truth: adding a new state AFTER the current terminal automatically shifts the terminal property without code edits. Corollary: callers must test returned values (`[ -n "$result" ]`) rather than assume a variable is always set — helpers return empty string on unmatched input, which is `set -u`-safe.
