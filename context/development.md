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

## Coding Conventions

- **Bash**: `set -euo pipefail` in all scripts; `content_stable_cp` is defined in `install.sh` (not `utils.sh`) for idempotent file copies; `utils.sh` provides only `OCG_CMD`
- **Bash sed portability**: `sed -i ''` (BSD macOS) not portable to GNU sed (Linux). Use temp-file rewrite: `sed 'EXPR' file >"${file}.tmp" && mv "${file}.tmp" file`. Canonical: `install.sh` lines 474–483 (mktemp/cmp/mv pattern). Mutation scripts in `shared/scaffold/` use this idiom throughout.
- **Multi-line block composition**: `printf "%b"` interprets `\n` in format+args, BUT `$()` strips trailing newlines. String concatenation + `%b` is fragile. Prefer `{ printf ...; printf ...; } >> file` for block writes.
- **Bash subshell export isolation**: Pipe subshells (`printf ... | fn`) execute in a subshell — exports invisible to outer process. Fix: write input to temp file, use file redirect (`fn < "$stdin_file"`) so exports propagate to parent scope.
- **Elixir module @moduledoc/@spec ordering**: credo's StrictModuleLayout requires `[:shortdoc, :moduledoc, :use, ...]` — `@moduledoc` ALWAYS after `defmodule ... do` and BEFORE `use`. Scaffold mutation credo_fix.sh enforces this.
- **Bash module name derivation**: Use `python3` one-liner for slug→CamelCase; pure-sed BRE is fragile across BSD/GNU + bash 3.2 case-fold gaps. Reference: `scaffold.sh` line 81.
- **Finding byte-identical lines across two files**: `comm -12 <(sort file1) <(sort file2)` — intersection idiom. Primary use: detecting harness header drift; used by `tools-header-no-dup_test.sh`.
- **Prose-fix planning: anchor to exact text, not line numbers**: Always cite exact sentence/phrase to edit — never line numbers. Line numbers drift as files evolve.
- **Ordered-list item insertion anchoring**: Anchor to TEXT of current first item (not section header). Pattern: `Read` file → locate exact anchor text → `Edit` with anchor text in old_string.
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

  See `harnesses/pi/pi-extensions/enforcement/src/hooks/__tests__/stop-resume.test.ts` for working example. **Regex anchors**: JavaScript does not support `\z`; use string-split extraction. **Markdown parsing**: prefer `split("## ")` + slice over regex for section body extraction. **TS try/catch fail-open**: wrap entire multi-step resolution chain in one `try/catch`; any step throwing is caught uniformly → exit 0 (allow). No per-step null guards needed. Differs from bash where guards must be chained explicitly.

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

- **Split extraction: verify last line is load-bearing, not meta** — When extracting a H2-cluster from a source file that contains a trailing meta section (e.g., `## Update When Changing`), stop the extraction boundary BEFORE the meta section. Extractors pull to EOF by default; over-extraction includes unintended footer sections that belong in the original file. Always verify the extracted content's last H2 header is the intended terminal cluster, not a meta marker. Use grep `^## ` to detect H2 boundaries before finalizing extraction ranges.
- **`make install` registry/settings.json parity** — when adding a `kind: registration` entry in `shared/enforcement/registry.yaml`, BOTH the registry.yaml entry AND the committed `harnesses/claude/claude-code-settings.json` entry must be present before parity checks pass. Workflow: (1) add registry.yaml entry, (2) add .sh file with HOOK-MANIFEST header, (3) run `make install` to regenerate settings.json, (4) commit both changed files together.
- **`make install` gated on python3, node, yq-mikefarah** — `apt install yq` installs python-yq (incompatible, silently wrong manifest parsing) — use mikefarah/yq binary instead.
- **`npm install` at codegen root required before hook use** — root `node_modules/` (ajv, playwright, prettier) must exist for schema-validate.js and render-check.js; install.sh runs this automatically. Absent → verification hooks emit INCONCLUSIVE.
- **`make install` required after any rule/template change** — running agents see the old baked prompts otherwise
- **Root node_modules absence is a trap** — hooks silently degrade (INCONCLUSIVE verdict) if ajv/playwright unresolvable.
- **Chromium binary absence is fail-closed on static boxes** — Static-site build gate BLOCKS (not skips) when Chromium missing. Benchmark screenshot capture tolerates missing Chromium; the gate does not.
- **`mise trust` runs unconditionally on install** — enforcement `.mise.toml` is now trusted without `OCG_NONINTERACTIVE` gate; interactive installs no longer hang on trust prompt.
- **Do not run `npm install` at repo root for Pi extensions** — each extension has its own node_modules; only root install is managed by install.sh
- **Hook test failures are not ExUnit** — `make test` runs bash tests + hermetic ExUnit; they are separate suites
- **Hook test runner summary pattern mismatch — `run-tests.sh` blind spot** — The `run_one` function in `run-tests.sh` checks `grep -qE "failed [1-9]"` but test output format is `"<digit> failed"` (number before word). Pattern never matches, so tests with 1+ failures pass silently at the `run-tests.sh` summary level. Mitigation: test failures still trigger via `assert_eq` assertions during test execution, and `make test` gate passes/fails correctly despite the summary bug — the failure happens at test-invocation time (exit code), not at `run-tests.sh` summary parsing. Not a gate blocker, but worth documenting to avoid confusion during hook test debugging.
- **`make test-stacks` must never regress to bare `mix test`** — gate uses `mix test --only slow`; bare `mix test` silently runs ZERO stack tests and exits 0 (fake-green). Always tag LLM-driven tests with `:slow`.
- **config.yaml structure: anchor to block shape, not value** — When editing config.yaml, two or more blocks may contain the same leaf value (e.g., `model: opus` appears in both `harness.shape.claude` at line 89 and `roles.shape` at line 164). The dead `harness.shape.claude` block is single-line: `{ model: opus, effort: high }`; the live `roles.shape` block spans 4 lines. Edit's `old_string` MUST include surrounding context (full 4-line block for roles.shape) to avoid landing in the dead block. Use `yq '.roles.shape.model' config.yaml` to verify which block was edited post-change.
- **Pitch line numbers are estimates** — developer MUST Read the actual file to locate exact anchor text before Editing. Pitch approximations drift as file history accumulates.
- **Example blocks in reference documents may also carry routing targets** — when bulk-repathing or correcting paths in a reference/mapping file (e.g., `context/curator-routing.md`), check that inline example blocks, case studies, or callouts within the section body also get repathed. Pitfalls: an Ambiguous Cases example might cite `shared/rules/_core/hooks.md` expecting rewrite to `codegen/rules/_core/hooks.md`; catching this requires a final grep of the entire edited section, not just the main bullets. Remedy: after `old_string`/`new_string` replacements, run a search for the old path pattern in the modified file and confirm all hits are either (a) repathed or (b) inside warning/denial prose ("never edit raw...").
- **Phoenix-colocated esbuild requires compile-before-build chain** — `phoenix-colocated` import in `app.js` only exists after `mix compile`; `assets.build` + `assets.deploy` aliases must include `"compile"` prefix.
- **`CODEGEN_DIR` must be absolute** — relative paths break symlink resolution in launchers
- **Session log filename format must include `_HHMMSS`** — non-canonical forms (e.g., `YYYYMMDD-slug.md`) are blocked by reviewer-guard and dev-gate hooks at Edit time
- **Transcript lag in print-mode builds** — on-disk JSONL may lag the live stream. `session_log_from_transcript()` implements a build-scoped fallback. See `context/hooks.md` § Transcript Lag & Discovery Pattern.
- **Makefile recipes run under `/bin/sh`, not bash** — process substitution fails. Use pipeline patterns instead of bash-specific syntax.
- **Makefile doctor pattern for binary presence** — `executablePath()` returns a path even when binary NOT downloaded; must test `fs.existsSync()` to confirm download completion.
- **Build mode uses baked tools, shape/ops/debug modes use runtime config** — `build-tools.txt` is baked at `make install` time. Shape/ops/debug launchers invoke `load-role.sh` to read `config.yaml` at invocation time. Planner pitch claims about config.yaml changes must be verified against working tree before trust.
- **Flaky tests often indicate state leakage, not async timing** — investigate persistent state first (counter files, temp dirs, session IDs). Counter files from `runHook()` (e.g., `claude-autoship-guard-<sessionId>.count`) persist across test runs; add explicit cleanup in `afterEach`.
- **TypeScript test isolation: capture streams at test-body scope** — not in `beforeEach`/`afterEach`. Restore streams in both resolve and reject paths. **Bash test temp-file cleanup**: temp files in helpers (e.g., `/tmp/_test_stdout*$$`) can leak; use `mktemp` + explicit per-call `rm`, or create all per-call temps under the root trap-cleaned directory. **Layered fixture setup for fail-path tests**: build fixtures in layers: innermost (project repo clean) → intermediate (symlink committed) → outermost (new-check dirty state). Then assert the intended check fires.
- **Node 22+ test concurrency and process-global state** — Node 22+ runs `describe()` children concurrently. When tests use `process.chdir()`, add `{ concurrency: 1 }` to `describe()`. **Pi test disk-read patterns**: hook tests that call `fs.existsSync()` or `fs.readFileSync()` on a specific path must create a real temp file at that exact path. **Pi test helper extension**: extend helpers with optional 4th params spread into tool input — existing callers unaffected. **npm run build precedence**: Pi tests run against `dist/` (compiled output), not `src/`. Always `npm run build` BEFORE `npm test`.
- **`chmod 000` is a no-op under root** — Tests making files unreadable via `chmod 000` must not assume restriction holds under root.
- **Clean-tree gate enforces one-commit-per-cycle rule** — `build-no-success-before-commit.sh` blocks BUILD_RESULT: success if `git status --porcelain` non-empty. All dirty/untracked files must be gitignored or committed.
- **Rule-file includes are static at install time, not runtime** — fix requires THREE steps: (1) edit the rule file, (2) add `{% include %}` directive to the role-def template, (3) run `make install`. Plan discovery without implementation produces a dry audit — no live change.
- **When a plan specifies dynamic-enumeration engine, verify implementation does it** — Hard-coding paths contradicts the design guarantee. Always inspect the implementation; description alone is not evidence of execution.
- **prompt-content-parity_test.sh sentinel sync** — When a rule file changes load-bearing text, parity-test sentinels MUST be updated to match exactly. Assertions use `grep -qF` (fixed-string grep). Sentinels must target SOURCE rule files, not baked install-destination paths. **Pre-validation**: grep `prompt-content-parity_test.sh` for rule-file names being added; zero hits → no sentinel sync needed. **Sentinel retargeting when content relocates**: retarget the parity-test file-path arg to the new location — sentinel STRINGS remain unchanged when content moves verbatim.
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
- **Planner-guard blocks Read on certain rule files** — `subagent-read-discipline.sh` denies planner Read to `testing-liveview.md` and `reviewer.md`. Workaround when planning prose edits to these files: use `Grep tool with -C context` to capture verbatim anchor text (exact sentence/phrase) instead of relying on line numbers. Planner can cite the extracted anchor in the pitch, developer confirms via their own Read, and Grep output is part of the pitch record.
- **Context files carry a 40 KB advisory cap** — `context/*.md` domain files have a ~40,960-byte (40 KB) advisory size limit. No enforced hook exists; constraint is advisory to guide curation load-balancing across the context-file suite. When a file approaches cap, compress redundancy or relocate verbose examples to another context file. The separate `context-file-size-gate` work item will harden this into an automated check.

## Deployment / Distribution

Codegen runs on servers too — combobulate prod/staging and the Hetzner dashboard box all run codegen, in addition to operator Macs. Distribution = `make install` on each machine; each derives its root from `BASH_SOURCE`, never hardcoded. CI validates that scaffold output compiles and hook tests pass. PRs require both `make test` and `make test-stacks` green before merge. See `context/deployment-topology.md`.

## Bash Patterns & Pitfalls (Codegen-Infra)

- **COMMON_FLAGS array** — dispatch scripts use a shared flags array for mode-invariant vs mode-specific flags. Build array once, splice into both exec paths. Under `set -u`, guard VALUE expansions with `if [[ ${#arr[@]} -gt 0 ]]; then` — `${arr[@]+"${arr[@]}"}` is rejected by shfmt; use explicit length-guards.
- **Shared fns called from multiple harnesses** — thread a `mode` parameter to gate harness-specific behavior. Example: `render-check.js` `runChecks(url, timeoutMs, mode)` gates content-region check on `if (mode === "phoenix")`.
- **`local` keyword in conditional blocks under `set -u`** — `local` in `if`/`elif` body at main-script scope silently fails. Use bare assignment. Function scope: `local` is safe. Also: `local var_name` inside `if` branch persists stale values across loop iterations — reset all branch-locals at loop top: `local repo_url="" tree_ref=""`.
- **Portable sed** — `sed -i ''` (macOS BSD) NOT portable to GNU sed (Linux). Use temp-file rewrite or `sed -i.bak 's/old/new/' file && rm -f *.bak` (non-empty extension works on both).
- **Bash 3.2 compatibility** — macOS system bash is 3.2: no `declare -A` (use indexed array + awk filter), no `wait -n` (use `wait "$pid"` loop). Reference: `post-developer-format.sh`, `codegen-document`.
- **IFS multi-char join** — `IFS=', '; echo "${arr[*]}"` uses ONLY first char as separator. To join with `', '`: `printf '%s, ' "${arr[@]}" | sed 's/, $//'`.
- **`cut` mixed delimiters** — `cut -d: -f2` on `dep:1.0.0|url|ref` captures the entire `|...` tail. Chain: `cut -d: -f2 | cut -d'|' -f1` to extract just the version.
- **Heredoc expansion** — unquoted `<<EOF` expands `$`-variables; quoted `<<'EOF'` does not.
- **Grep footguns** — `grep -v "substring"` deletes ENTIRE lines. When a line must survive in transformed form, process it BEFORE the drop condition. `grep` BRE treats `\(` as GROUP — use `grep -F` for literal strings with parens. `grep` assertions inside `eval` double-collapse backslashes — use `grep -qF`.
- **Shell test binary stubbing** — create a fake_bin_dir, symlink standard tools into it, omit target binary, filter `$PATH`, run tested block in subshell. Use `command -v TOOL` (not `which`) — `command` is a builtin, portable on bash 3.2+.
- **Conditional final statements** — `[ condition ] && action` as last statement flips exit code when condition is false. Use `if/then/fi` + explicit `return 0`.
- **VERBOSE gating** — `if [ -n "${VERBOSE:-}" ]; then printf 'debug'; fi; return 0` — the `if/fi` form does NOT flip exit code (unlike `&&` one-liner).
- **Post-condition assertions in mutations** — validate preconditions (file exists, anchor present) and postconditions (expected lines added, placeholders resolved). `eex_render.sh` should fail on unresolved `<%= ... %>` placeholders.
- **Cleanup wrappers & exit code propagation** — `bash -c "cmd; rm -rf $TMP"` loses the inner exit code if cleanup succeeds. Pattern: `RESULT=0; inner_cmd || RESULT=$?; cleanup_code; exit $RESULT`.
- **Fail-closed refute in tests** — to prove a script aborts BEFORE an irreversible action, use a shimmed subprocess marker: stub the irreversible command to record if called, then `refute` the marker was set.
- **Advisory health checks** — embed advisory output in same SSH output blob; parse verdict gate by reading ONLY gate-specific labels. Never include advisory section in `if [ ... ]` gate logic.
- **Multi-prompt headless gates** — one independent env var per interactive prompt. Example: `DEPLOY_AUTO=1` skips confirm; `DEPLOY_AUTO_ROLLBACK=1` (separate) skips rollback prompt.
- **Operator toggles vs app runtime config** — `DEPLOY_AUTO=1`, `RELEASE_DAY_OVERRIDE=1` etc. belong in script header comments, NOT in `.env.sample`.
