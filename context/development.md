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
- **Bash sed portability**: `sed -i ''` (BSD macOS) is not portable to GNU sed (Linux). Use temp-file rewrite instead: `sed 'EXPR' file >"${file}.tmp" && mv "${file}.tmp" file`. Canonical reference: `install.sh` lines 474–483 (mktemp/cmp/mv pattern). Mutation scripts in `shared/scaffold/` use this idiom throughout.
- **Multi-line block composition**: `printf "%b"` interprets `\n` in both format string and arguments, BUT `$()` command substitution strips trailing newlines from captured output. Composing multi-line blocks via string concatenation + `%b` is fragile (newlines disappear between segments). Prefer grouped `{ printf ...; printf ...; } >> file` for block writes — ensures unambiguous newlines and is more readable.
- **Bash subshell export isolation**: Pipe subshells (`printf ... | fn`) are executed in a subshell and swallow exports — `${VAR}` set inside a piped subshell is invisible to the outer process. Fix: write input to a temp file and use file redirect (`fn < "$stdin_file"`) so the call happens in the same shell process and exports propagate outward to the parent scope. This pattern is essential for tests that verify exported variables (e.g., `ssh-target_test.sh` T-new-12/13 asserting `${OPS_ALIAS}` export).
- **Elixir module @moduledoc/@spec ordering**: credo's StrictModuleLayout requires `[:shortdoc, :moduledoc, :use, ...]` order — `@moduledoc` ALWAYS comes AFTER `defmodule ... do` and BEFORE `use`. Scaffold mutation credo_fix.sh enforces this when injecting @moduledoc into generated files.
- **Bash module name derivation**: When converting slug to CamelCase module names, use `python3` one-liner (`python3 -c '...capitalize join...'`); pure-sed BRE is fragile across BSD/GNU + bash 3.2 case-fold gaps. Reference: `scaffold.sh` line 81.
- **Finding byte-identical lines across two files**: Use `comm -12 <(sort file1) <(sort file2)` to find lines present in BOTH files (comm's `-12` output = intersection). This idiom avoids a second grep pass and is the idiomatic bash pattern for byte-set equality checks. Primary use case: detecting harness header drift (identifying lines that should be moved from per-harness headers to shared bodies because they are already byte-identical across both harnesses). The detector test `tools-header-no-dup_test.sh` uses this pattern to catch regressed duplicates and enforce prompt-assembly discipline.
- **Ordered-list item insertion anchoring**: When inserting a new highest-priority item into an ordered blocker scan list (e.g., adding a new check to shape.txt step-2), anchor to the TEXT of the current first item in the ordered list (not the section header). This ensures the edit lands exactly before the intended position, regardless of line-number drift between sessions. Pattern: `Read` the file to locate exact anchor text (e.g., `**Unverified empirical claims** — ...`), then `Edit` with the anchor text in old_string and the full multi-line bullet insertion in new_string. Avoids brittle line-number dependencies.
- **Parallel Read then parallel Edits for independent single-line insertions**: When making multiple independent single-line insertions into different files (e.g., adding three `{% include %}` lines to three separate `.md.j2` templates), Read all target files in parallel first to confirm anchor text presence and position, then execute all Edits in parallel. No ordering dependencies between edits means parallelization is safe and reduces round-trip latency. Verify anchors in reads before editing to catch typos or position drift.
- **Scaffold.sh Phase pattern for new directories**: The canonical model for "ensure directory exists + placeholder file" additions is scaffold.sh Phase 3 (`priv/plts` + `.keep` file). New lifecycle directories follow this shape: Phase block with `mkdir -p` + `touch .gitkeep` + echo status message. Example: codegen/pitches dirs (draft, ready, shipped) added via Phase 3b loop over the three dirs. When adding new directory lifecycle, use the same Phase numbering + heredoc/echo pattern as existing phases (cf. session 20260612_115417 scaffold.sh Phase 3b implementation).
- **Python**: stdlib only in generator scripts — no third-party deps. One-liner scripts (e.g., module name derivation) can use python3 directly in Bash heredocs.
- **TypeScript**: strict mode; each extension self-contained with own `package.json`. **Test isolation under parallel runners**: when tests capture stderr/stdout (e.g., to verify error handling), move capture to test-body scope rather than `beforeEach`/`afterEach` hooks — this ensures each test owns its capture window and avoids cross-test pollution under concurrent test runners. Restore streams in both resolve and reject paths to prevent leakage on assertion failure. Pattern: capture inside test body, not in beforeEach; restore in finally block on both pass and throw paths. Example:

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

  See `harnesses/pi/pi-extensions/enforcement/src/hooks/__tests__/stop-resume.test.ts` for working example. **Regex anchors**: JavaScript does not support `\z` (PCRE end-of-string anchor); use string-split extraction instead. **Markdown parsing**: avoid regex for section body extraction; prefer `split("## ")` + slice pattern to find boundaries explicitly.

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
- Chromium browser binary — `make install` guarantees this on static-capable boxes (those where `npm list playwright` succeeds); `make doctor` verifies the binary is present. Manual install: `npx playwright install chromium`

**Two separate subsystems with different failure modes** (cf. session 20260608_153448):

1. **Benchmark screenshots** — `BenchArtifacts.capture_screenshot/4` (ExUnit test phase). Missing Playwright is **non-fatal**: logs `playwright not installed — skipping screenshot capture` and returns `:ok`. JSONL bench records are always written regardless of screenshot availability.
2. **Static-site render gate** — `static-site-build-check.sh` (SubagentStop hook). **Fail-closed**: if Chromium is absent on a static-capable box, the gate blocks the developer subagent with a clear error message. This is NOT the same as benchmark behavior — the gate requires Chromium, while benchmarks tolerate its absence. Conversely, both use Playwright/Chromium; the distinction is whether missing installation is permitted (benchmarks) or denied (gate).

## Runtime Porting — Reduced Fidelity Across Harnesses

When porting a guard/hook from Claude (Bash) to Pi (TypeScript), the runtime capabilities may differ:

- **Transcript access**: Claude has JSONL transcript inspection via `jq` + `TRANSCRIPT_PATH`; Pi has no transcript. Guards depending on "Agent X called without Log Write" (transcript-based detection) cannot be ported with full fidelity. Honest approach: write a reduced-fidelity observe-only twin with disk-scan heuristics + explicit header comment documenting the gap. Never fake full parity with a guard that actually does something weaker; always document the capability difference.
- **Event blocking asymmetry**: Claude's Stop event can block (enforces constraint); Pi's `session_shutdown` is observe-only (warns to stderr, cannot block). Ports of Stop guards to Pi are observational. Convention: all 4 Stop/SubagentStop twins emit stderr warnings, NEVER `block()` — the Pi runtime ignores blocking results on shutdown events.

The goal is truthful hooks that accurately reflect capability limits, not feature parity claims that hide missing capabilities.

## Scaffold File Rendering Order

Integrate-stage renders (PROJECT_CONTEXT, restart_server.sh, usage_rules_INDEX) run BEFORE the git commit to ensure all new files are captured in a single atomic commit point (codegen-scaffold do_create):

1. Stack-specific scaffold.sh completes file writes (phx.new for Phoenix, inline heredocs for static)
2. `run_integrate_stage` renders cross-stack files from templates (eex_render.sh for both stacks, since static reuses phoenix's generic eex_render)
3. Git commit runs after integrate-stage (single commit point for both stacks)
4. Atomic mv from temp parent to final location

This order eliminates the dirty-tree race: if integrate-stage files rendered AFTER the commit (old phoenix pattern), they would be uncommitted → `git status --porcelain` non-empty → build failure. Single commit in codegen-scaffold captures everything.

Three-part writer absorption: (1) boundary neutralisation first (consumer-name removal from PROJECT_CONTEXT templates + scaffold.sh comments), (2) new templates second (restart_server.sh.eex, usage_rules_INDEX.md), (3) arg-parsing + renders third (codegen-scaffold --restart-rpc-cmd parsing, integrate-stage render calls).

## Common Pitfalls

- **`make install` registry/settings.json parity** — when adding a new hook registration (e.g., `kind: registration` entry in `shared/enforcement/registry.yaml`), BOTH the registry.yaml entry AND the committed `harnesses/claude/claude-code-settings.json` entry must be present before `make install` parity checks pass. The compiler regenerates settings.json from the registry, then diffs it against the committed version; divergence fails the `make hook-parity` check (part of `make test`). Workflow: (1) add registry.yaml entry, (2) add .sh file with HOOK-MANIFEST header, (3) run `make install` to regenerate settings.json, (4) commit both changed files together. Intermediate state (registry entry only, settings.json stale) will block `make test`.
- **`make install` gated on python3, node, yq-mikefarah** — fresh-box installs fail loud if build-critical tools missing (not jq/rg, which install.sh installs). Verify `yq --version | grep -qi mikefarah`; `apt install yq` installs python-yq (incompatible, silently wrong manifest parsing) — use mikefarah/yq binary instead.
- **`npm install` at codegen root required before hook use** — root `node_modules/` (ajv, playwright, prettier) must exist for schema-validate.js and render-check.js; install.sh now runs this automatically. If absent, verification hooks emit INCONCLUSIVE (cannot run, not passed).
- **`make install` required after any rule/template change** — running agents see the old baked prompts otherwise
- **Root node_modules absence is a trap** — hooks silently degrade (INCONCLUSIVE verdict) if ajv/playwright unresolvable. Run `npm install` at codegen root or rely on install.sh to do it.
- **Chromium binary absence is fail-closed on static boxes** — `make install` installs Chromium when playwright is present; `make doctor` verifies it. Static-site build gate BLOCKS (not skips) when Chromium is missing on a static-capable install. Benchmark screenshot capture tolerates missing Chromium (non-fatal); the gate does not. Two separate paths with different constraints.
- **`mise trust` runs unconditionally on install** — enforcement `.mise.toml` is now trusted without `OCG_NONINTERACTIVE` gate; interactive installs no longer hang on trust prompt.
- **Do not run `npm install` at repo root for Pi extensions** — each extension has its own node_modules; run per-extension dir (only root install is managed by install.sh)
- **Hook test failures are not ExUnit** — `make test` runs bash tests + hermetic ExUnit; `make test-stacks` runs slow ExUnit with real LLM; they are separate suites
- **`make test-stacks` must never regress to bare `mix test`** — gate uses `mix test --only slow`; bare `mix test` would silently run ZERO stack tests and exit 0 (fake-green) due to `test_helper.exs: exclude: [:slow]`. Always tag LLM-driven tests with `:slow` and verify gate test count rises when adding tests. See `context/test-harness.md` § Gate Invariant.
- **Pitch line numbers are estimates** — when a pitch specifies "edit line ~49", planner provides approximate guidance only; developer MUST Read the actual file to locate the exact anchor text before Editing. Pitch approximations drift as file history accumulates; anchoring to real content (not line numbers) is the robust pattern (cf. session 20260610_082318_commit-message-quality-audit where pitch said claude lines 42–49, actual was 46–53).
- **Phoenix-colocated esbuild requires compile-before-build chain** — `phoenix-colocated` import in `app.js` only exists after `mix compile`; `assets.build` + `assets.deploy` aliases must include `"compile"` prefix or esbuild fails to resolve the import (cf. session 20260608_174414)
- **`CODEGEN_DIR` must be absolute** — relative paths break symlink resolution in launchers
- **Session log filename format must include `_HHMMSS`** — orchestrator creates logs with canonical `YYYYMMDD_HHMMSS_slug.md` naming; non-canonical forms (e.g., `YYYYMMDD-slug.md`) are blocked by reviewer-guard and dev-gate hooks at Edit time
- **Transcript lag in print-mode builds** — on-disk transcript JSONL in non-interactive builds may lag the live stream; hook discovery of session logs can return empty even though files exist on disk. `session_log_from_transcript()` implements a build-scoped fallback (filesystem search when transcript-bound jq returns nothing). See `context/hooks.md` § Transcript Lag & Discovery Pattern for full mechanics.
- **Makefile recipes run under `/bin/sh`, not bash** — process substitution (`< <(...)`) fails even on macOS where `/bin/sh` is bash-compat. Use pipeline patterns (`cat file | grep | tr | sed`) instead of bash-specific syntax in Makefile recipes and variable assignments.
- **Makefile doctor pattern for binary presence** — when using `node -e` inline to check for a binary (e.g., Chromium), use `$$` for shell variable interpolation (Make variable) and `$(VAR)` for Make variables. Example: `node -e "const path = require('playwright').chromium.executablePath(); if(!require('fs').existsSync(path)) throw new Error()"` — note `executablePath()` returns a path even when the binary is NOT downloaded; must test `fs.existsSync()` to confirm download completion (cf. session 20260608_153448).
- **Flaky tests often indicate state leakage, not async timing** — investigate persistent state first (counter files, temp dirs, session IDs) before blaming concurrency. Example: counter files from `runHook()` calls (e.g., `claude-autoship-guard-<sessionId>.count`) persist across test runs; add explicit cleanup in `afterEach` to prevent accumulation and retry-cap failures every ~3rd run.
- **TypeScript test isolation: capture streams at test-body scope** — when tests capture stderr/stdout to verify error handling, move capture to the test-body scope rather than `beforeEach`/`afterEach` hooks. Ensures each test owns its capture window and avoids cross-test pollution under parallel runners. Restore streams in both resolve and reject paths to prevent leakage on assertion failure.
- **Node 22+ test concurrency and process-global state** — Node 22+ runs `describe()` children concurrently by default. When tests use `process.chdir()`, they pollute the process cwd for all concurrent siblings. Fix: add `{ concurrency: 1 }` to `describe()` to serialize when touching process-global state (cwd, env, streams). Model on `enforcement/src/hooks/__tests__/` test files.
- **`chmod 000` is a no-op under root** — Tests that make files unreadable via `chmod 000` must not assume the permission restriction holds when running under root (e.g., in some CI environments). Root bypasses file permissions; `[ ! -r ]` tests will still return true. Design tests to assert only the success branch (deny message present) rather than testing the fail-open path directly under root.
- **Clean-tree gate enforces one-commit-per-cycle rule** — `build-no-success-before-commit.sh` blocks BUILD_RESULT: success if `git status --porcelain` is non-empty. No allowlist; all dirty/untracked files must be gitignored or committed. This is the backstop enforcing "all cycle output in one commit" rule — partial snapshots are forbidden.
- **Rule-file includes are static at install time, not runtime** — when a role-def subagent template (e.g., `planner-phoenix.md.j2`) discovers it lacks coverage of a rule file (e.g., `generators.md` containing phx.gen.live forbiddance rules), the fix requires THREE steps: (1) edit the rule file itself or relocate content, (2) add `{% include %}` directive to the role-def template, (3) run `make install` to regenerate and reinstall prompts to `~/.claude/`. Plan discovery of missing coverage without implementation produces a dry audit report — no live change occurs. The actual fix requires editing the subagent template and running the install cycle. Example: audit session 20260612_121603 found three coverage gaps: `planner-phoenix.md.j2` missing `generators.md`, `reviewer-phoenix.md.j2` missing `testing-liveview.md`, and `manifest-external-resource.md` unused in all role-defs. These require subagent template edits, not just documentation.
- **When a plan specifies dynamic-enumeration engine, verify implementation does it** — A spec like "parse settings.json, filter array, strip prefix, prepend SCRIPT_DIR" is aspirational until confirmed in code. Hard-coding the paths contradicts the design guarantee that a future config entry would auto-participate. Always inspect the implementation; description alone is not evidence of execution. Example: a composition test engine that claims to "enumerate registered hooks from claude-code-settings.json" must actually parse the JSON with jq/python, not hard-code three hook paths.
- **prompt-content-parity_test.sh sentinel sync** — When a rule file (e.g., `shared/rules/stacks/phoenix/reviewer.md`) changes in load-bearing text (wording changes that affect what a reviewer/dev checks), parity-test sentinels MUST be updated to match the new prose EXACTLY. Assertions use `grep -qF` (fixed-string grep), so backticks/slashes in sentinels must appear verbatim as in the source. Rule: pick sentinels that ARE the load-bearing rule prose (the phrase a reviewer keys on), not a separate marker — this ensures any future reword that keeps the meaning keeps the sentinel. For shape-specific labels (shape.txt ASK-GATE labels like "product forks only", INTERACTION-AUDIT), also update any near-verbatim copies in other files (e.g., ready.md.j2 for /ready command) — test sentinel MUST match or parity fails on first run. Assertions must target SOURCE rule files (e.g., `$CODEGEN_DIR/shared/rules/stacks/phoenix/reviewer.md`), not baked install-destination paths (e.g., `~/.claude/agents/`), because baked prompts are machine-specific and not in-repo. **Pre-validation strategy for include-list changes**: Before making include-list edits to `.md.j2` templates, grep `prompt-content-parity_test.sh` for the rule-file names being added (e.g., `generators.md`, `manifest-external-resource.md`); zero hits → no sentinel sync needed; non-zero → sentinels already exist and must be updated verbatim if the prose in the rule files changes. **Sentinel retargeting when content relocates**: When rule content moves verbatim to a new file (e.g., `_core.md` section → `testing-liveview.md`), retarget the parity-test file-path arg to the new location — sentinel STRINGS remain unchanged because the content moves verbatim. This preserves the "fact still exists somewhere" guarantee while following the physical relocation. Always Grep the parity test for the moved STRINGS (not just file names) before trusting a claim that no sentinel sync is needed. See context/hooks.md § Subagent-included rule files for full mechanics.
- **`PROJECT_CONTEXT.md` blocks the Read tool** — `subagent-read-discipline.sh` gate denies Read on `PROJECT_CONTEXT.md` to non-planner roles. To edit it: use Grep to find anchor text, then edit directly via Bash with the mktemp/cmp/mv pattern (cf. `install.sh` lines 474–483). Example: `TEMP_FILE=$(mktemp); sed 's/old/new/' "$TARGET" >"$TEMP_FILE"; if cmp -s "$TEMP_FILE" "$TARGET"; then rm "$TEMP_FILE"; else mv "$TEMP_FILE" "$TARGET"; fi`. Idempotent and portable across BSD/GNU sed.
- **Scoped removal of multi-category tokens** — "cursor" appears in three independent categories: (1) Pi TUI text-caret identifiers (`cursorIndex`, `moveCursor`), (2) multi-IDE interop (`~/.cursor/mcp.json` reads, `CURSOR_API_KEY` env scrubbing), (3) codegen's own IDE coupling (`open_cursor_workspace()` fn). Removal pitches must scope to one category — blanket grep-delete breaks the others. Always verify post-edit: `Grep "removed_token"` → expect zero hits, then `Grep -i "removed_token"` → verify survivors are all expected categories (e.g., text-caret only, not IDE coupling).
- **`git status --porcelain` on fresh fixtures requires explicit commit** — test fixtures using `git init` to create a repo for testing dirty-tree detection must commit all fixture files BEFORE checking `git status --porcelain`. A newly initialized repo with pre-existing untracked files is reported as dirty by `--porcelain` (all files are untracked). To create a "clean tree" fixture for asserting state transitions, run `git init` + `git add -A` + `git commit` to establish a baseline, then create stray files for the dirty case. Pattern: `git init tmp; cd tmp; echo 'fixture' >file.txt; git add file.txt; git commit -m 'init' && echo 'fixture clean' >file2.txt && git status --porcelain` yields only file2.txt (dirty). See session 20260612_115417 stop-cycle-guard_test.sh Test 21 fix.
- **Pi test fixtures for gate-result checks must commit gate-result.json** — When writing Pi hook tests that verify behavior against `codegen/gate-pending/gate-result.json` (e.g., verdict=clear check), the JSON file must be committed as part of the git fixture tree, OR the `codegen/gate-pending/` directory path itself must be in .gitignore. Otherwise, `git status --porcelain` detects the untracked directory and triggers the dirty-tree check BEFORE the intended new check in the hook runs, causing tests to fail with the wrong verdict (clean-tree block instead of verdict block). Pattern: use `fs.mkdirSync(..., {recursive:true})` + `fs.writeFileSync()` to create gate-result.json, then `git add` the directory before `process.chdir()` into the fixture. Applies to any check that is positioned before the existing clean-tree check in the hook sequence — earlier checks must be satisfied by the fixture.
- **`dev-no-self-gate` blocks after 3 invocations per session** — The hook `developer-no-self-gate.sh` enforces a hard limit: developer role can invoke its own gate command (`make test` in codegen, `mix test` in downstream) at most 3 times per session. On the 4th invocation, orchestrator is blocked with a clear message to escalate to the gate hook (run `make test` at orchestrator level, not developer). This is a backstop to prevent gate-check loops. When iterating on fixes during development, run targeted tests (bash script directly: `bash harnesses/claude/hooks/stop-cycle-guard_test.sh`, or npm test in extension dir) rather than the full gate, to verify before triggering gate slots for the orchestrator's final gate run.
- **Recovering and re-wiring deleted scripts** — When restoring a deleted script from git history (e.g., `git show <commit>^:script.sh`), strip dead env/config dependencies FIRST (OCG_CONTEXT_DIR blocks, config.sh/utils.sh sources, ~/.ocg/config.json agent blocks, deprecated --agent flags, orphaned callsites to deleted binaries like run-ai.sh). Then systematically repoint each callsite to current primitives (e.g., `codegen-call` for LLM calls, `$CODEGEN_DIR` from `BASH_SOURCE` for path resolution). One-pass systematic substitution across the recovered script prevents missing re-wire callsites. Example: `codegen-document` (session 20260612_172059) recovered usage_rules.sh, removed dead OCG_CONTEXT_DIR + config.sh sourcing, and replaced the old agent invocation with `codegen-call --harness claude_code --role usage-rules ...`.
- **Single variable binding propagates to multiple interpolation sites** — When a Bash function assigns a versioned URL or similar derived variable at a single point (e.g., line 131 in `codegen-document`), that binding threads into all later interpolation sites within the same function scope (4+ usage points). Pinning the variable at the assignment site (e.g., via if/else guard on semver format) updates all interpolations with no further edits — the propagation is automatic via shell variable expansion in heredocs and string concatenation. Verify propagation via Grep before assuming aliasing is broken. Example: `${hexdocs_url}` in `codegen-document` threads into fetch instruction + **Source:** link at lines 151/174/201/220 — a single if/else at line 131 updates all four without additional changes.
- **FORBIDDEN extension for external contracts uses OR, not AND** — When strengthening a FORBIDDEN clause that already says "must execute the code path", the correct extension for external-contract probes is "OR exercise the external contract" — the two are disjoint paths (in-repo execution vs external endpoint exercise), joined by OR, not AND. Example: "FORBIDDEN: claim external behavior without either (1) executing the repo code path that invokes it, OR (2) exercising the external contract directly via curl/WebFetch/WebSearch probe." The two techniques are alternatives, not cumulative requirements.
- **Spread technique for external probes requires exactly 4 numbered rules** — When adding a section that guides users to probe external outcomes with a representative spread, structure it as exactly 4 numbered steps: (1) name the axis (which external property changes), (2) probe both ends (success and failure boundaries), (3) single-sample is inconclusive (articulate the rule explicitly), (4) failure case is mandatory (require at least one negative case). This 4-step structure makes the guidance mechanically actionable for users — not advisory. See shape.txt "Unverified empirical claims" blocker for reference implementation.
- **Semantic equivalence vs structural identity in prompt-body sibling files** — When reviewing prompt-body changes across sibling files that feed the SAME generated artifact (e.g., shape.txt + ready.md.j2, both → shape system prompt), verify semantic equivalence of all rules, NOT literal step-count parity. Compression that preserves all semantic rules is correct mirroring. Example: shape.txt may use 4 bold-labeled numbered steps; ready.md.j2 may compress to 3 steps folding the "inconclusive rule" into step 2 — semantically identical (all four concepts present), structurally different (3 vs 4 steps). "Near-verbatim" intent is satisfied by semantic equivalence without requiring identical structure.

## Deployment / Distribution

Codegen runs on servers too — combobulate prod/staging and the Hetzner dashboard box all run codegen, in addition to operator Macs. Distribution = `make install` on each machine (server or Mac); each derives its root from `BASH_SOURCE`, never hardcoded. CI validates that scaffold output compiles and hook tests pass. PRs require both `make test` and `make test-stacks` green before merge. See `context/deployment-topology.md`.
