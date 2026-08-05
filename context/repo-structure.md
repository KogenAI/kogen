# Repo Structure Domain — Physical Layout of the Codegen Repository

Structural map of the codegen repo: what each top-level file and directory contains, why it exists, and what creates or updates it. Use it to answer "where does X go?" or decide where a new file belongs. For functional detail, see cross-references at the bottom.

**Key fact — AGENTS.md / CLAUDE.md at repo root**: Both are committed regular files (git mode 100644), hand-authored and NOT auto-rendered. To change content, edit the files directly (no `.j2` template sources them). Downstream repo docs (`AGENTS.md`/`CLAUDE.md`) are rendered from `shared/apps/AGENTS-phoenix.md.j2` and `shared/apps/AGENTS-static.md.j2` via `install.sh` — but the root codegen-repo AGENTS/CLAUDE are separate, independent guidance files for agents working in THIS repo.

```
codegen/                          ← repo root
├── ocg                           ← user CLI dispatcher (symlinked to PATH)
├── codegen-build                 ← harness API entrypoint
├── codegen-call                  ← one-shot structured LLM call binary
├── codegen-scaffold              ← one-time downstream app provisioning
├── codegen-analyze               ← read-only turn-waste analyzer; scans Claude transcripts; prints ranked report
├── install.sh                    ← manifest-driven harness installer
├── uninstall.sh                  ← manifest-driven harness uninstaller
├── update_ai_tools.sh            ← post-install tool updater
├── config.sh                     ← shared env/path config (sourced by all scripts)
├── resource_manager.sh           ← port allocator (see context/port-allocation.md)
├── utils.sh                      ← shared bash utilities (OCG_CMD)
├── bash_completion.sh            ← shell tab-completion for ocg commands
├── Makefile                      ← build surface (install, test, format, doctor…)
├── package.json                  ← root npm manifest (prettier only)
├── package-lock.json             ← lockfile for root prettier dep
├── index.html                    ← static-site test fixture (NOT a site page)
├── AGENTS.md                     ← codegen session loop docs (hand-authored regular file)
├── CLAUDE.md                     ← codegen session loop docs (hand-authored regular file)
├── PROJECT_CONTEXT.md            ← codegen project context for AI agents
├── README.md                     ← user quickstart guide
├── STYLE_GUIDE.md                ← cross-cutting style reference
├── analysis/                     ← stdlib-Python turn-waste analysis package (counters, loader, report writer)
├── bin/                          ← single dev-utility script (test-llm-hooks.sh)
├── codegen/                      ← self-meta directory (THIS repo's session logs + pitches)
├── context/                      ← domain context files (AI orientation)
├── coverage/                     ← test coverage output (gitignored; per-language subdirs)
├── docs/                         ← contributor guides
├── harnesses/                    ← per-harness launchers, hooks, settings
├── node_modules/                 ← npm packages (prettier; gitignored)
├── shared/                       ← runtime artifacts (rules, recipes, subagents…)
├── templates/                    ← generator pipeline + .j2 source templates
├── tmp/                          ← ephemeral scratch space (gitignored)
└── test_harness/                 ← ExUnit scaffold test suite
```

---

## Entry-Point Scripts

| File               | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Caller                                   |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `ocg`              | User CLI dispatcher — wraps `make` targets; symlinked to `$PATH`; sets `OCG_CLI=true` for ocg-only targets                                                                                                                                                                                                                                                                                                                                                     | End users, shell tab-completion          |
| `codegen-build`    | Harness API — `--harness`, `[--stack]`, `--cwd`, `--model`, `--effort`, `--max-budget-usd`, `--fallback-model`, `--print-dir`, `--print-argv`; stack auto-detected from cwd markers; delegates to `harnesses/<harness>/dispatch.sh`. `--max-budget-usd` → `CODEGEN_BUILD_MAX_BUDGET_USD` → enforced argv cap to `mix codegen.loop` (absent = no cap). `--print-argv` dry-runs only. Flags pinned by `harnesses/claude/hooks/fixtures/codegen-build-flags.txt`. | Platform, CI, downstream Makefiles       |
| `codegen-scaffold` | App provisioning — `create` (full scaffold), `integrate` (symlinks only); delegates to `shared/scaffold/<stack>/scaffold.sh`                                                                                                                                                                                                                                                                                                                                   | Platform setup, `ocg setup`              |
| `codegen-call`     | One-shot LLM call — `--harness`, `--model`, `--effort`, `--system-prompt @<path>`, optional `--json-schema @<path>`                                                                                                                                                                                                                                                                                                                                            | Consuming platform, single-response      |
| `codegen-analyze`  | Turn-waste analyzer — `--since`, `--json`, `--raw`, `--window`, `--threshold-reread`, `--project-dir`; read-only                                                                                                                                                                                                                                                                                                                                               | Operators, CI, manual inspection         |
| `codegen-propose`  | Proposal drafter — `--since` (required), `--max`, `--min-wasted-turns`; pipes analyzer output through `analysis.proposer.select`; writes `codegen/analysis-proposals/<from>_<to>.md` (ephemeral)                                                                                                                                                                                                                                                               | Operators reviewing turn-waste           |
| `codegen-log`      | Sole writer of append-only JSONL cycle logs (`init`/`section`/`append`/`verdict`/`relocate`/`show`); contract: `shared/rules/_core/session-log.md`                                                                                                                                                                                                                                                                                                             | Loop, subagents; `show` is operator-only |
| `codegen-document` | Generates/refreshes `shared/usage_rules/<lib>-<version>.md` hex API summaries + regenerates `INDEX.md`                                                                                                                                                                                                                                                                                                                                                         | Contributors adding a hex dep            |
| `codegen-advise`   | Wraps `codegen-call`; flips to OPPOSITE provider (fixed map); `{plan, confidence}` out. See `context/loop.md` § Opposite-Provider Advisor.                                                                                                                                                                                                                                                                                                                     | Loop give-up boundary, `advise` tool     |

`ocg` = user-facing (menu, doctor, install). `codegen-build` = machine API for downstream Makefiles. Never conflate them.

---

## Lifecycle & Support Scripts

| File                  | Purpose                                                                                                                                                                                                                                                          | Trigger                            |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `install.sh`          | Reads `manifest.yaml` fields (paths, dirs); hardcodes its own install phases directly (generate agents, register hooks, write settings.json, symlink) — the manifest's `install_steps:` field is declared but read by nothing                                    | `make install` / `ocg install`     |
| `uninstall.sh`        | Removes installed artifacts; hardcodes its own removal phases directly — does NOT read manifest `uninstall_steps:` or source `resource_manager.sh` (that script is the port allocator, see `context/port-allocation.md`, unrelated to install-artifact tracking) | `make uninstall`                   |
| `update_ai_tools.sh`  | Updates Claude CLI binary and AI tool deps                                                                                                                                                                                                                       | `make update` / `ocg update`       |
| `config.sh`           | Defines `CODEGEN_DIR`, `SHARED_DIR`, harness paths, model defaults; sourced by every script                                                                                                                                                                      | All scripts (sourced)              |
| `resource_manager.sh` | Port allocator — NOT an install-artifact tracker; unrelated to `install.sh`/`uninstall.sh`. Full domain: `context/port-allocation.md`                                                                                                                            | (see `context/port-allocation.md`) |
| `utils.sh`            | `OCG_CMD`. Note: `content_stable_cp` lives in `install.sh`, not here.                                                                                                                                                                                            | Harness launchers, scaffold        |
| `bash_completion.sh`  | Tab-completion for `ocg` subcommands; installed into shell profile                                                                                                                                                                                               | Shell (bash/zsh via profile)       |

---

## Make Targets

| Target                    | Purpose                                                                                                                                                                                  |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make install`            | Full install cycle: hook-parity → render settings → install.sh                                                                                                   |
| `make test`               | Two-phase: parallel parity/scaffold/npm checks, then serial tail (hooks, hermetic ExUnit, rule-render-freshness); tracked-tree backstop; fast, no LLM calls                              |
| `make test-stacks`        | ExUnit scaffold tests both harnesses; slow, real LLM calls; pre-deploy gate                                                                                                              |
| `make test-all`           | `test` + `test-stacks` + `record-green`                                                                                                                                                  |
| `make hook-parity`        | Verify `claude-code-settings.json` hook entries match hook source dir                                                                                                                    |
| `make harness-path-check` | Grep baked agents (`~/.claude/agents`) for stale harness-relative paths; fails if found                                                                                                  |
| `make harness-parity`     | Verify `codegen-build` + `dispatch.sh` stubs are self-consistent                                                                                                                         |
| `make format`             | Format git-intent files only (`git ls-files -co --exclude-standard`) via `harnesses/shared/repo-format.sh`; shell candidates go through `shfmt`, supported text formats through Prettier |
| `make doctor`             | Check required tools on PATH (claude, jq, rg, mise, pyyaml); exits non-zero on fail                                                                                                      |
| `make build-ready`        | Preflight gate: doctor + installed-harness currency (vs `.ocg-install-stamp`) + `make test`; refuses (exit 2) on any red — for gating drain dispatch to a remote box before a paid run   |
| `make record-green`       | Write `test_harness/last_green.json` with current commit SHA + tool versions                                                                                                             |
| `make uninstall`          | Remove installed claude harness artifacts (ocg-only guarded)                                                                                                                             |
| `make update`             | Update AI agents (ocg-only guarded)                                                                                                                                                      |

---

## Root Documentation Files

| File                 | Audience                       | Content                                                     | Status                                 |
| -------------------- | ------------------------------ | ----------------------------------------------------------- | -------------------------------------- |
| `AGENTS.md`          | AI sessions (agents render)    | Codegen session loop: what it is, dev loop, workspace rules | Committed regular file (hand-authored) |
| `CLAUDE.md`          | AI sessions (claude render)    | Same content as AGENTS.md; hand-authored                    | Committed regular file (hand-authored) |
| `PROJECT_CONTEXT.md` | AI orchestrators               | Session analyzer command, gate commands, key paths          | Committed                              |
| `README.md`          | New users / contributors       | Installation steps, prerequisites, quick-start              | Committed                              |
| `STYLE_GUIDE.md`     | All contributors and AI agents | Naming conventions, formatting rules, review checklist      | Committed                              |

---

## Top-Level Directories

| Directory       | Purpose                                                                                                                                                                     | Key paths                                                                                                                                                                                         |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `analysis/`     | Stdlib-Python turn-waste analysis package — counters, session loader, report writer, tests. Run via `codegen-analyze` launcher.                                             | `analysis/counters/`, `analysis/tests/`, `analysis/tests/fixtures/`                                                                                                                               |
| `bin/`          | Dev utility scripts not in the build pipeline. Not binaries on `$PATH`.                                                                                                     | `bin/test-llm-hooks.sh` (manual LLM hook test; no Makefile target)                                                                                                                                |
| `codegen/`      | Self-meta session logs + pitches for codegen-on-codegen dev. Separate from downstream project `codegen/` dirs. Also holds `codegen-propose` output (`analysis-proposals/`). | `codegen/logging/*.jsonl` (active cycle logs), `codegen/pitches/{draft,ready,building,shipped,archive,studio}/`, `codegen/analysis-proposals/<from>_<to>.md` (proposed-change records, ephemeral) |
| `context/`      | Domain context files — one file per functional domain; read by the orchestrator for orientation, and by a cycle role only when the pitch's `scope:` put the path in the loop's `files_to_touch` grant. Updated by context-curator subagent post-reviewer.                   | `context/*.md`                                                                                                                                                                                    |
| `coverage/`     | Test coverage output (gitignored). Per-language subdirs written by `make test-coverage`.                                                                                    | `coverage/python/`, `coverage/shell/`, etc.                                                                                                                                                       |
| `docs/`         | Contributor guides for multi-file coordinated tasks. Not AI orientation (that's `context/`).                                                                                | `docs/adding-a-harness.md`                                                                                                                                                                        |
| `harnesses/`    | Per-harness launchers, hook scripts, settings, manifest, slash commands.                                                                                                 | `harnesses/claude/`, `harnesses/shared/`                                                                                                                                               |
| `node_modules/` | Root prettier dep only. Gitignored.                                                                                                                                         | Root only; `npm install` at repo root to regenerate                                                                                                                                               |
| `shared/`       | Runtime artifacts installed/rendered into downstream agents: rules, recipes, subagents, scaffold, usage_rules.                                                              | `shared/rules/`, `shared/recipes/`, `shared/subagents/`, `shared/scaffold/`, `shared/usage_rules/`                                                                                                |
| `templates/`    | Generator pipeline + `.j2` sources for codegen infrastructure. Distinct from `shared/` (runtime).                                                                           | `templates/generator/`                                                                                                                                                                            |
| `test_harness/` | Elixir/ExUnit project for end-to-end scaffold validation. Slow (real LLM) + fast hermetic (deterministic). Mix path wire: `elixirc_paths(:test)` in `mix.exs`.              | `test_harness/test/stacks/`, `test_harness/test/codegen_test_harness/`, `test_harness/last_green.json`                                                                                            |
| `tmp/`          | Ephemeral scratch space. Gitignored.                                                                                                                                        | —                                                                                                                                                                                                 |

### `harnesses/` key paths

| Path                                              | Purpose                                                                                  |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `harnesses/claude/dispatch.sh`                    | Mode dispatcher — selects launcher, execs claude                                         |
| `harnesses/claude/claude-build-system-prompt.txt` | **Generated** — do not hand-edit; regenerated by `make install`                          |
| `harnesses/claude/claude-code-settings.json`      | Source settings: hook registrations, permissions, env vars                               |
| `harnesses/claude/manifest.yaml`                  | Claude harness install contract                                                          |
| `harnesses/claude/hooks/`                         | 50 hook scripts (PostToolUseFailure, PreToolUse, Stop) + paired `_test.sh` + `lib/`      |
| `harnesses/claude/commands/`                      | Slash command sources → installed to `~/.claude/commands/` at install time               |
| `harnesses/shared/prompt-bodies/`                 | Shared prompt body text (concatenated with `tools-header/` at generate time)             |

### `shared/` key paths

| Path                   | Purpose                                                                                     |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| `shared/apps/`         | Downstream AGENTS.md/CLAUDE.md/PROJECT_CONTEXT templates copied by `codegen-scaffold`       |
| `shared/recipes/`      | Hand-authored implementation guides; naming: `<stack>-<topic>.md`; read by developers        |
| `shared/rules/`        | Discipline rules baked into subagent prompts via `{% include %}` at generate time           |
| `shared/rules/_core/`  | Universal rules: bash discipline, cwd, output style, session log                            |
| `shared/rules/roles/`  | Per-role rules: committer, context-curator, developer, reviewer                             |
| `shared/rules/stacks/` | Stack rules: `phoenix/` (Elixir/LiveView), `static/` (Tailwind v4, Vite)                    |
| `shared/enforcement/`  | Declarative enforcement registry (`registry.yaml`) + schema docs; compiler generates hooks  |
| `shared/scaffold/`     | `scaffold.sh` + `mutations/` + `.eex` templates used by `codegen-scaffold`                  |
| `shared/subagents/`    | `.md.j2` templates rendered into per-harness agent prompts installed to `~/.claude/agents/` |
| `shared/usage_rules/`  | Machine-generated hex library API summaries; one file per library-version                   |

### `templates/generator/` key files

| File                    | Purpose                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------ |
| `generate.sh`           | Renders `.md.j2` templates for a named harness into `templates/generated/`           |
| `process_template.py`   | Jinja-style `{% include %}` processor; inlines rules/recipes into subagent templates |
| `hook_registrations.py` | Generates hook entries in `claude-code-settings.json` from hook source dir           |
| `config.yaml`           | Maps role names to model IDs, effort levels, tool configs                            |
| `manifest-lib.sh`       | Bash lib wrapping `yq` for manifest field extraction                                 |

---

## Artifact Ownership and Update Triggers

| Artifact                                          | Owner                                        | Updated by                                                        | Trigger                                                                              |
| ------------------------------------------------- | -------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `harnesses/claude/claude-code-settings.json`      | Generator                                    | `hook_registrations.py`                                           | `make install` or `make hook-parity`                                                 |
| `harnesses/claude/claude-build-system-prompt.txt` | Generator                                    | `generate.sh`                                                     | `make install`                                                                       |
| `AGENTS.md` (repo root)                           | Hand-authored regular file (git mode 100644) | Direct edit; no `.j2` source or install.sh render step            | When codegen session loop docs change                                                |
| `CLAUDE.md` (repo root)                           | Hand-authored regular file (git mode 100644) | Direct edit; no `.j2` source or install.sh render step            | When codegen session loop docs change                                                |
| `shared/` (all subdirs)                           | Contributors / curator                       | Manual edit or context-curator subagent                           | Feature development, learning accumulation                                           |
| `context/*.md`                                    | Context curator                              | `context-curator.md.j2` subagent + manual                         | Post-reviewer in each dev cycle                                                      |
| `codegen/logging/*.md`                            | Orchestrator + subagents                     | Session log write/edit during dev sessions                        | Every dev cycle on THIS repo                                                         |
| `codegen/analysis-proposals/<from>_<to>.md`       | `codegen-propose`                            | Overwritten each `codegen-propose` run                            | Manual operator run; ephemeral, gitignored                                           |
| `test_harness/last_green.json`                    | CI / `record-green.sh`                       | `make record-green` after `make test-all` passes                  | Pre-deploy gate                                                                      |
| Root `node_modules/`                              | npm                                          | `npm install` at repo root                                        | After `package.json` changes                                                         |
| `shared/enforcement/registry.yaml`                | Contributors / curator                       | Manual edit; compiler reads at `make install`                     | When adding/changing denial rules                                                    |
| `shared/enforcement/seam-registry.yaml`           | Contributors / curator                       | Manual edit; `seam-registry-parity_test.sh` checks at `make test` | New/removed declaration↔reflection seam (twin, generated pair, index)                |
| `shared/usage_rules/INDEX.md`                     | `codegen-document`                           | Regenerated after `codegen-document` writes corpus files          | After any hex dep generation; per-dep prose carried forward by key, citations fresh  |
| `shared/scaffold/SCHEMA_VERSION`                  | Maintainers                                  | Manual bump (plain integer)                                       | When a scaffold change requires apps to consciously re-integrate                     |
| `<app>/codegen/manifest.yaml` (downstream)        | `codegen-scaffold` (`run_integrate_stage`)   | ALWAYS-REWRITE (not write-once) on every `create`/`integrate`     | Every scaffold integrate run; `codegen-build` refuses when stamped version is behind |
| `harnesses/claude/hooks/no-*.sh` (generated)      | `enforcement_compiler.py`                    | `make install` (compiler step)                                    | When `registry.yaml` changes                                                         |

---

## Notable Artifacts

- **`shared/apps/AGENTS-phoenix.md.j2` / `AGENTS-static.md.j2`** — sources for downstream AGENTS.md/CLAUDE.md. Rendered by `install.sh`. Rendered `.md` targets are committed; include in commits when `.j2` changes.
- **`templates/generator/`** — pipeline core: `generate.sh` + `process_template.py` + `hook_registrations.py`. See `context/core.md`.
- **`harnesses/claude/hooks/`** — 50 scripts (one rule each + paired `_test.sh`). See `context/hooks.md`.
- **`shared/subagents/`** — `.md.j2` templates rendered into prompts via `{% include %}`. See `context/subagents.md`.
- **`test_harness/`** — ExUnit suite: slow (real LLM, `--only slow`), hermetic (deterministic, `--exclude slow`). See `context/test-harness.md`.
- **`index.html`** — static-stack test fixture (not served).
- **`package.json`** (root) — `prettier` only; `"private": true`.
- **`shared/usage_rules/` vs `shared/recipes/`** — machine-generated API summaries vs hand-authored patterns.
- **`*-system-prompt.txt`** — generated by `make install` (gitignored; ephemeral).
- **`analysis/proposer/`** — `codegen-propose` consumer; filters+ranks `codegen-analyze` clusters.
- **`shared/scaffold/SCHEMA_VERSION`** — source of truth for downstream staleness; `codegen-build` refuses when behind.
- **`.ocg-install-stamp`** — install-currency stamp (machine-local, never committed).
- **`shared/enforcement/seam-registry.yaml`** — declaration↔reflection seam inventory; checked at `make test`.
- **`harnesses/claude/document-system-prompt.md`/`document.schema.json`** — headless drafter; `codegen-advise` mirrors this pair.

---

## Critical Constraints

- [ ] **One-way knowledge boundary**: Codegen docs MUST NOT name any downstream consumer. Use "the consuming app" / "downstream projects". `grep -ri "<consumer-name>" context/ AGENTS.md CLAUDE.md` must return zero hits. Consumer-specific VALUES arrive as scaffold ARGs (`--slug`, `--restart-rpc-cmd`), never hardcoded in codegen source. Multi-file boundary fixes require guard test coverage of EVERY file in the intended grep target, not a curated subset — narrow guards silently miss future violations.
- [ ] **Downstream consumer repos' `CLAUDE.md`/`AGENTS.md` are committed symlinks (mode 120000)** — they point at generated `shared/apps/CLAUDE-phoenix.md` and `shared/apps/AGENTS-phoenix.md` respectively; the rendered `.md` targets are committed/tracked (not gitignored). To change content, edit the `.j2` template and run `make install`, which regenerates the `.md` files. Include them in the commit. When codegen self-builds, `codegen-build` skips the integrate pre-step to prevent re-symlinking over the committed symlinks. **This does NOT apply to codegen's own root `AGENTS.md`/`CLAUDE.md`** — see next bullet.
- [ ] **AGENTS.md and CLAUDE.md at codegen repo root are hand-authored regular files (git mode 100644)** — verified via `ls -la` / `git ls-files -s`; NOT symlinks. Edit them directly; no `.j2` template sources exist and `install.sh` does NOT render them. These are independent guidance files for agents working in THIS codegen repo (distinct from downstream consumer repos' auto-rendered, symlinked AGENTS.md/CLAUDE.md described above).
- [ ] **Generated `*-system-prompt.txt` files** — never hand-edit; regenerated by `make install`. These files are gitignored (`.gitignore:35` pattern `*-system-prompt.txt`), NOT committed tracked artifacts — they regenerate on install and are local-machine ephemeral, unlike `shared/apps/*.md` (committed generated files, see § Notable Artifacts). A pitch MUST NOT ask a developer to commit these system-prompt files.
- [ ] **`codegen/` at repo root** is THIS repo's own session log + pitch storage — entirely separate from downstream project `codegen/` dirs.
- [ ] **`content_stable_cp`** lives in `install.sh`, not `utils.sh`.
- [ ] **Rules are baked at install time** — subagents do not read rule files at runtime. Change a rule → `make install` to propagate.
- [ ] **Domain context files (`context/*.md`) NOT mirrored to AGENTS/CLAUDE** — The root session-loop docs (`AGENTS.md` and `CLAUDE.md`) mirror only the codegen session-loop narrative and build rules, not individual domain context files. Edits to `context/harnesses.md`, `context/hooks.md`, etc., DO NOT propagate to AGENTS.md/CLAUDE.md via symlink or template include.
- [ ] **Repo root differs per machine/OS** — Linux servers (`~/apps/codegen` on the dashboard box) vs operator Macs (`~/Areas/Optimum/codegen`). NOTHING hardcodes it; scripts derive `CODEGEN_DIR` from `BASH_SOURCE`. See `context/deployment-topology.md`.
- [ ] **Cycle logs never enter git** — gitignored, machine-local, permanently; `codegen-log` has no publish/sync subcommand. Never rebuild an equivalent branch/ref/note/stash. See `context/cycle-record.md` § No Git-Tracked Logs.

---

## Cross-References

| Topic                                                  | File                                  |
| ------------------------------------------------------ | ------------------------------------- |
| Generator pipeline, manifest schema, install lifecycle | `context/core.md`                     |
| Harness launchers, dispatch, system prompt assembly    | `context/harnesses.md`                |
| Hook scripts, registration, lifecycle events           | `context/hooks.md`                    |
| Recipe catalog                                         | `context/recipes.md`                  |
| Core discipline rules                                  | `context/rules-core.md`               |
| Per-role rules                                         | `context/rules-roles.md`              |
| Per-stack rules                                        | `context/rules-stacks.md`             |
| Downstream app scaffolding                             | `context/scaffold.md`                 |
| Subagent templates and Jinja include graph             | `context/subagents.md`                |
| ExUnit stack test suite                                | `context/test-harness.md`             |
| Dev loop, tech stack, make targets                     | `context/development.md`              |
| Subagent system prompt assembly layers                 | `context/subagent-influence-stack.md` |
| Claude token budget and context window behavior        | `context/claude-token-mechanics.md`   |
| Deployment locations & path derivation                 | `context/deployment-topology.md`      |

---

## Trigger Keywords

repo layout, structure, where does X go, file tree, top-level files, codegen root, which directory, where to add, artifact location, file organization, repo anatomy, ocg vs codegen-build, ai-agents orphaned, self-meta codegen/, codegen/logging, context vs templates, shared vs templates, bin/ utilities, CLAUDE.md symlink, AGENTS.md source, codegen-propose, analysis-proposals, proposed-change record, turn-waste to proposal, scaffold schema version, per-app manifest, staleness preflight, codegen-build refuse, SCHEMA_VERSION, codegen-advise, opposite-provider advisor, advise tool, advisor_plan, `mcp__codegen__advise`, stuck build second opinion

---

## Update When Changing

Update this file when:

- A new top-level directory is added to the repo root
- An existing directory's purpose changes (e.g., `ai-agents/` gains actual content)
- A new root-level script or config file is added
- The install pipeline writes to a new destination path
- A `context/*.md` file is added or removed
- The `templates/` generator pipeline gains new output artifacts
- `bin/` gains additional scripts
- The `codegen/` self-meta structure changes
