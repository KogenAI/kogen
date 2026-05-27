# Repo Structure Domain — Physical Layout of the Codegen Repository

This file documents the physical layout of the codegen repository: what each top-level file and directory contains, why it exists, and what creates or updates it. Use it to answer "where does X go?", to orient after encountering an unfamiliar artifact, or to decide where a new file belongs. It is a structural map, not a functional guide — for functional detail on any domain, see the cross-references at the bottom.

```
codegen/                          ← repo root
├── ocg                           ← user CLI dispatcher (symlinked to PATH)
├── codegen-build                 ← harness API entrypoint
├── codegen-scaffold              ← one-time downstream app provisioning
├── install.sh                    ← manifest-driven harness installer
├── uninstall.sh                  ← manifest-driven harness uninstaller
├── update_ai_tools.sh            ← post-install tool updater
├── config.sh                     ← shared env/path config (sourced by all scripts)
├── resource_manager.sh           ← installed-artifact tracker
├── utils.sh                      ← shared bash utilities
├── bash_completion.sh            ← shell tab-completion for ocg commands
├── Makefile                      ← build surface (install, test, format, doctor…)
├── package.json                  ← root npm manifest (prettier only)
├── package-lock.json             ← lockfile for root prettier dep
├── index.html                    ← static-site test fixture (NOT a site page)
├── AGENTS.md                     ← orchestrator rules (plain file, pi render)
├── CLAUDE.md                     ← symlink → AGENTS.md (claude render)
├── PROJECT_CONTEXT.md            ← codegen project context for AI agents
├── README.md                     ← user quickstart guide
├── STYLE_GUIDE.md                ← cross-cutting style reference
├── ai-agents/                    ← sparse placeholder (see note below)
├── bin/                          ← single dev-utility script
├── codegen/                      ← self-meta directory (THIS repo's session logs)
├── context/                      ← domain context files (AI orientation)
├── docs/                         ← contributor guides
├── harnesses/                    ← per-harness launchers, hooks, settings
├── node_modules/                 ← npm packages (prettier; gitignored)
├── shared/                       ← runtime artifacts (rules, recipes, subagents…)
├── templates/                    ← generator pipeline + .j2 source templates
└── test_harness/                 ← ExUnit scaffold test suite
```

---

## Root-Level Files

### Entry-Point Scripts

| File               | Role                                                                                                                                                                                                      | Who calls it                                                   |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `ocg`              | User CLI dispatcher — wraps `make` targets with a friendly interface; symlinked into `$PATH` at install time; sets `OCG_CLI=true` so Makefile can gate ocg-only commands                                  | End users, shell tab-completion                                |
| `codegen-build`    | Harness API — canonical entrypoint for all harness-based build invocations; accepts `--harness`, `--stack`, `--cwd`, `--model`, `--effort`, `--max-turns`; delegates to `harnesses/<harness>/dispatch.sh` | Platform, CI, downstream app Makefiles, direct dev invocations |
| `codegen-scaffold` | One-time provisioning — scaffolds a new downstream Phoenix or static-site project from templates; accepts `--stack`, `--cwd`, `--slug`; delegates to `shared/scaffold/<stack>/scaffold.sh`                | Platform setup, `ocg setup`                                    |

`ocg` vs `codegen-build`: `ocg` is user-facing (menu, doctor, install). `codegen-build` is the machine API that downstream Makefiles call to invoke an AI build session. Never conflate them.

### Lifecycle Scripts

| File                 | Purpose                                                                                                                                         | Trigger                             |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `install.sh`         | Reads `harnesses/<harness>/manifest.yaml`, runs declared install steps (generate agents, register hooks, write settings.json, symlink binaries) | `make install` or `ocg install`     |
| `uninstall.sh`       | Removes artifacts listed in manifest `uninstall_steps`; reads `resource_manager.sh` tracker to avoid removing unowned files                     | `make uninstall` or `ocg uninstall` |
| `update_ai_tools.sh` | Post-install: updates Claude CLI binary and AI tool dependencies to latest versions                                                             | `make update` or `ocg update`       |

### Support Libraries

| File                  | Purpose                                                                                                                                       | Sourced by                                           |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `config.sh`           | Shared env/path config — defines `CODEGEN_DIR`, `SHARED_DIR`, harness paths, model defaults; sourced by every script that needs codegen paths | `install.sh`, `codegen-build`, all harness launchers |
| `resource_manager.sh` | Tracks which files were installed by ocg vs pre-existing; prevents orphaned artifacts on uninstall                                            | `install.sh`, `uninstall.sh`                         |
| `utils.sh`            | Common bash utilities: logging helpers, `content_stable_cp` (copy only if content changed), path normalization                                | Harness launchers, scaffold scripts                  |
| `bash_completion.sh`  | Provides tab-completion for `ocg` subcommands; installed into shell profile by `install.sh`                                                   | Shell (bash/zsh via profile source)                  |

### Build Surface (Makefile)

| Target                | Purpose                                                                                                              | Notes                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `make install`        | Full install cycle: `hook-parity` check → generate pi-extension → render hooks into settings.json → run `install.sh` | Primary dev loop entrypoint                       |
| `make test`           | Run bash hook unit tests via `run-tests.sh` + pi-extension npm tests                                                 | Fast; no LLM calls                                |
| `make test-stacks`    | Run ExUnit scaffold tests for both harnesses in parallel partitions                                                  | Slow; real LLM calls; pre-deploy gate             |
| `make test-all`       | `test` + `test-stacks` + `record-green`                                                                              | Full pre-deploy gate                              |
| `make hook-parity`    | Verify `claude-code-settings.json` hook entries match the hook source directory                                      | Runs before every `make install`                  |
| `make rule-parity`    | Diff `AGENTS.md` / `CLAUDE.md` against fresh render of `templates/AGENTS-HYBRID.md.j2`                               | Catches drift between template and committed file |
| `make harness-parity` | Verify `codegen-build` + `dispatch.sh` stubs are self-consistent                                                     | Runs `codegen-build_test.sh` + `scaffold_test.sh` |
| `make format`         | Format all shell scripts with `shfmt` and all other files with `prettier`                                            | Uses `mise exec` for tool version isolation       |
| `make doctor`         | Check required tools on PATH (claude, jq, rg, mise, pyyaml) and config files                                         | Diagnostic only; exits non-zero on failures       |
| `make record-green`   | Write `test_harness/last_green.json` with current commit SHA + tool versions                                         | Only runs after all tests pass                    |
| `make uninstall`      | Remove global CLI installation (ocg-only guarded)                                                                    | Via `ocg uninstall`                               |
| `make update`         | Update AI agents (ocg-only guarded)                                                                                  | Via `ocg update`                                  |

### Documentation Files

| File                 | Audience                                                          | Content                                                                    |
| -------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `README.md`          | New users / contributors — user quickstart                        | Installation steps, prerequisites, quick-start commands                    |
| `AGENTS.md`          | AI orchestrators (pi harness render) — runtime rules              | Orchestrator rules, agent workflow, delegation chain, INCONCLUSIVE table   |
| `CLAUDE.md`          | AI orchestrators (claude harness render) — symlink to `AGENTS.md` | Same content; separate file so Claude Code loads it by convention          |
| `STYLE_GUIDE.md`     | All contributors and AI agents — cross-cutting style              | Naming conventions, formatting rules, review checklist                     |
| `PROJECT_CONTEXT.md` | AI orchestrators starting a session — orientation snapshot        | Session analyzer command, gate commands, key paths, harness dispatch guide |

**Important**: `AGENTS.md` is a plain file (pi render). `CLAUDE.md` is a symlink pointing to `AGENTS.md`. Both are generated from `templates/AGENTS-HYBRID.md.j2` — hand-editing either is overwritten by `make install`. The authoritative source is the template. Run `make rule-parity` to detect drift.

### Root-Level Oddities

| File                | Why it exists                                                                                          | What it is NOT                                                           |
| ------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `index.html`        | Test fixture used by `test_harness/test/stacks/static/` tests to assert static-site build output shape | Not a project homepage; not meant to be served                           |
| `package.json`      | Declares `prettier` as a dev dependency for `make format`                                              | Not a project npm package; has no build/serve scripts; `"private": true` |
| `package-lock.json` | Locks prettier version                                                                                 | Auto-generated; update by running `npm install` at repo root             |

---

## Top-Level Directories

### `ai-agents/`

```
ai-agents/
  claude/
    commands/        ← sparse: no files (commands installed to ~/.claude/commands/ instead)
  opencode/          ← empty placeholder
```

**Purpose**: Originally intended as the destination for installed agent files. Now orphaned. `install.sh` writes agent files to `~/.claude/agents/` and `~/.pi/agents/`, not here.

**Do not add files here** expecting them to be installed or loaded. The directory exists as a structural artifact from an earlier design. The `ai-agents/claude/commands/` path is empty — slash commands live in `harnesses/claude/commands/` (source) and are installed to `~/.claude/commands/` (destination).

---

### `bin/`

```
bin/
  test-llm-hooks.sh
```

**Purpose**: Developer utility scripts that are not part of the install or build pipeline. Currently contains exactly one file.

| File                    | Purpose                                                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `bin/test-llm-hooks.sh` | Manual developer utility for testing hook behavior against a live LLM session; not called by any Makefile target or CI pipeline |

**Naming note**: Despite the directory name, `bin/` does not contain binaries or scripts that are symlinked to `$PATH`. The user-facing binary is `ocg` (at repo root). Do not add install-pipeline scripts here.

---

### `codegen/`

```
codegen/
  context/           ← per-session context snapshots (self-meta)
  contexts/          ← older context snapshots (legacy)
  logging/           ← session log files (*.md) from dev sessions on THIS repo
  planning_sessions/ ← planner output from sessions on THIS repo
  plans/             ← plan artifacts
  workspaces/        ← workspace-scoped artifacts
```

**Purpose**: Self-meta directory. When contributors use the AI agent workflow to develop on the codegen repo itself, the session logs, planner outputs, and context snapshots land here — just as they would in `<project>/codegen/` for a downstream app.

This directory is specific to codegen-on-codegen development. Downstream projects get their own `codegen/` directory at their repo root; those directories are separate and are not here.

**Key rule**: `codegen/logging/*.md` files are the active session logs the orchestrator and subagents read/write during a codegen development session. The `step-log-missing-guard.sh` and `phoenix-dev-gate.sh` hooks discover active logs by scanning for `Write|Edit|MultiEdit` tool_use entries on paths matching `codegen/logging/*.md` in the transcript JSONL.

---

### `context/`

```
context/
  core.md
  development.md
  harnesses.md
  hooks.md
  pi-extensions.md
  recipes.md
  rules-core.md
  rules-roles.md
  rules-stacks.md
  scaffold.md
  subagent-influence-stack.md
  subagents.md
  test-harness.md
  repo-structure.md     ← THIS FILE
  claude-token-mechanics.md
  claude-token-tuning.md
```

**Purpose**: Domain context files for AI agents orienting on the codegen codebase. Each file covers one functional domain: what it does, what files implement it, key paths, and trigger keywords. Orchestrators and planners read these files to understand the codebase before delegating work.

**Who writes**: Context curator subagent (`shared/subagents/shared/context-curator.md.j2`) updates these files post-reviewer based on `### What I Learned This Step` blocks accumulated during a dev cycle. Contributors also edit directly when documenting new domains.

**Ownership rule**: Each `context/*.md` file owns its domain. Cross-domain pointers belong in a single file, not scattered.

| File                          | Domain covered                                                                |
| ----------------------------- | ----------------------------------------------------------------------------- |
| `core.md`                     | Manifest schema, generator pipeline, install/uninstall lifecycle              |
| `development.md`              | Dev loop, tech stack, make targets, environment configuration                 |
| `harnesses.md`                | Per-harness launchers, dispatch logic, system prompt assembly, settings       |
| `hooks.md`                    | Hook scripts, registration, bash test suite, lifecycle events                 |
| `pi-extensions.md`            | Pi TypeScript extensions (askuserquestion, enforcement, subagents, web-utils) |
| `recipes.md`                  | Recipe catalog — step-by-step implementation guides                           |
| `rules-core.md`               | Cross-cutting discipline rules included in every subagent                     |
| `rules-roles.md`              | Per-role rules (orchestrator, planner, developer, reviewer, committer)        |
| `rules-stacks.md`             | Per-stack rules (phoenix, static)                                             |
| `scaffold.md`                 | Downstream app scaffolding pipeline                                           |
| `subagent-influence-stack.md` | How subagent system prompts are assembled and what influences each layer      |
| `subagents.md`                | Subagent templates, roles, Jinja include graph                                |
| `test-harness.md`             | ExUnit scaffold test suite                                                    |
| `repo-structure.md`           | Physical repo layout (this file)                                              |
| `claude-token-mechanics.md`   | Claude token budget mechanics and context window behavior                     |
| `claude-token-tuning.md`      | Practical token tuning strategies for agent sessions                          |

---

### `docs/`

```
docs/
  adding-a-harness.md
```

**Purpose**: Contributor guides for non-trivial tasks that require multi-file coordination. Not AI orientation files (those are in `context/`). Not user quickstart (that is `README.md`).

| File                       | Audience                                         | Content                                                                      |
| -------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------- |
| `docs/adding-a-harness.md` | Contributors adding support for a new AI harness | Step-by-step: manifest, launcher scripts, dispatch, hooks, generate pipeline |

Add new docs here when a task requires coordinated changes across multiple subsystems that cannot be captured in a single domain context file.

---

### `harnesses/`

```
harnesses/
  claude/
    _claude-build/        ← build-mode rules/shared docs (used by dispatch)
    _claude-debug/
    _claude-refactor/
    _claude-shape/
    build-tools.txt
    claude-build.sh       ← build mode launcher
    claude-debug.sh
    claude-refactor.sh
    claude-shape.sh
    claude-build-config.json
    claude-build-system-prompt.txt   ← generated; do NOT hand-edit
    claude-debug-system-prompt.txt
    claude-refactor-system-prompt.txt
    claude-shape-system-prompt.txt
    claude-code-settings.json        ← source settings (hooks, permissions, env)
    dispatch.sh           ← mode dispatcher
    load-role.sh          ← resolves model/effort/tools from config.yaml
    manifest.yaml         ← claude harness install contract
    tools-header/         ← per-mode system prompt header fragments
    commands/             ← slash commands (installed to ~/.claude/commands/)
    hooks/                ← hook scripts + tests
  pi/
    _pi-build/
    _pi-debug/
    _pi-refactor/
    _pi-shape/
    dispatch.sh
    manifest.yaml
    pi-build.sh
    pi-debug.sh
    pi-refactor.sh
    pi-shape.sh
    pi-build-system-prompt.txt
    pi-debug-system-prompt.txt
    pi-refactor-system-prompt.txt
    pi-shape-system-prompt.txt
    tools-header/
    pi-extensions/        ← TypeScript npm packages
    pi-prompts/           ← Pi-specific prompt fragments
  shared/
    prompt-bodies/        ← shared prompt body text (build, debug, shape, refactor)
```

#### `harnesses/claude/`

The Claude harness. Contains everything specific to operating the `claude` CLI as the AI backend.

| File / Dir                       | Purpose                                                                                                                 |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `claude-build.sh`                | Build mode launcher — sets model/effort, invokes `claude` with system prompt and hooks                                  |
| `claude-debug.sh`                | Debug mode launcher (Opus, high effort)                                                                                 |
| `claude-shape.sh`                | Shape mode launcher (Opus, high effort, web tools enabled)                                                              |
| `claude-refactor.sh`             | Refactor mode launcher (Opus, high effort, web tools enabled)                                                           |
| `dispatch.sh`                    | Mode dispatcher — reads manifest, selects launcher, execs claude                                                        |
| `load-role.sh`                   | Reads `templates/generator/config.yaml` to resolve model/effort/tools for a given role name                             |
| `tools-header/`                  | Per-mode system prompt header fragments; prepended to shared prompt bodies at generate time                             |
| `claude-build-system-prompt.txt` | **Generated file** — concatenation of tools-header + prompt-body; do not hand-edit; regenerated by `make install`       |
| `claude-code-settings.json`      | Source Claude Code settings: hook registrations, permissions, environment variables; updated by `hook_registrations.py` |
| `claude-build-config.json`       | Build mode config: model, effort, tool allowlist                                                                        |
| `manifest.yaml`                  | Claude harness install contract — declares agents, hooks, launchers, modes, install/uninstall steps                     |
| `commands/`                      | Slash command source files installed to `~/.claude/commands/` at install time                                           |
| `hooks/`                         | Hook scripts (PreToolUse, SubagentStop, Stop) + paired `_test.sh` files + `lib/`                                        |
| `build-tools.txt`                | Tool allowlist for build mode                                                                                           |

#### `harnesses/claude/hooks/`

All hook scripts for the claude harness. Each hook enforces one discipline rule and has a paired `<name>_test.sh` hermetic bash test.

| Subdirectory / File                | Purpose                                                                                         |
| ---------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------- |
| `lib/hooks-lib.sh`                 | Shared bash library: `session_log_from_transcript`, role detection, gate verdict helpers        |
| `lib/gate-select.sh`               | Selects which gate to run based on stack detected in project                                    |
| `run-tests.sh`                     | Runs all `*_test.sh` files in parallel (up to 8 jobs); used by `make test`                      |
| `phoenix-dev-gate.sh`              | SubagentStop — runs Phoenix test suite, appends `ALL CLEAR / FAILED / INCONCLUSIVE` to step log |
| `static-site-build-check.sh`       | SubagentStop — builds static site, appends gate verdict                                         |
| `step-log-missing-guard.sh`        | Stop — blocks session exit if dev ran but no step log Write found in transcript                 |
| `stop-cycle-guard.sh`              | Stop — blocks premature stop before full delegation cycle completes                             |
| `stop-resume.sh`                   | Stop — resumes orchestration when session was interrupted mid-cycle                             |
| `session-log-section-integrity.sh` | PreToolUse — enforces `## <role> Section` header present before subagent Edit                   |
| `no-python-json.sh`                | PreToolUse — blocks inline `python3 -c` JSON parsing                                            |
| `no-cat-pipe.sh`                   | PreToolUse — blocks `cat file                                                                   | ...`, `head`, `tail` pipe patterns |
| `orchestrator-no-source-edit.sh`   | PreToolUse — blocks orchestrator from writing source files directly                             |
| `pre-commit-guard.sh`              | PreToolUse — blocks `git commit` outside committer role                                         |
| `subagent-read-discipline.sh`      | PreToolUse — blocks subagents from reading context files they should not touch                  |
| `context-curator-guard.sh`         | PreToolUse — enforces context curator edit scope                                                |

Full hook catalog: `context/hooks.md`.

#### `harnesses/claude/commands/`

Slash command source files. Installed to `~/.claude/commands/` at `make install` time. Each `.md` file becomes an available `/command` in Claude Code sessions.

| File                     | Slash command                             |
| ------------------------ | ----------------------------------------- |
| `command.md`             | `/command` — start a new build session    |
| `document.md`            | `/document` — run documentation mode      |
| `ready.md`               | `/ready` — check session readiness        |
| `release-new-version.md` | `/release-new-version` — release workflow |
| `rule.md`                | `/rule` — add a new rule                  |

#### `harnesses/pi/`

The Pi harness. Mirrors the claude harness structure but delegates to the `pi` CLI.

| File / Dir                                                       | Purpose                                                  |
| ---------------------------------------------------------------- | -------------------------------------------------------- |
| `pi-build.sh` / `pi-debug.sh` / `pi-shape.sh` / `pi-refactor.sh` | Mode launchers for Pi                                    |
| `dispatch.sh`                                                    | Pi mode dispatcher                                       |
| `manifest.yaml`                                                  | Pi harness install contract                              |
| `pi-extensions/`                                                 | TypeScript npm packages that extend Pi with custom tools |
| `pi-prompts/`                                                    | Pi-specific prompt fragments (one file: `document.md`)   |
| `tools-header/`                                                  | Per-mode system prompt header fragments                  |

#### `harnesses/pi/pi-extensions/`

TypeScript npm packages, each independently installable. Extend Pi with tools the base CLI does not provide.

| Extension          | Purpose                                                                         |
| ------------------ | ------------------------------------------------------------------------------- |
| `askuserquestion/` | Implements `AskUserQuestion` tool — interactive user prompts during Pi sessions |
| `enforcement/`     | Rule enforcement at runtime — blocks disallowed patterns (mirrors claude hooks) |
| `subagents/`       | Agent delegation bridge — enables Pi to delegate to subagents                   |
| `web-utils/`       | HTTP fetch, web search helpers                                                  |

Each extension has its own `package.json`, `src/`, compiled output, and `node_modules/`. Do not edit compiled output directly — edit `src/` and rebuild.

Full domain: `context/pi-extensions.md`.

#### `harnesses/shared/`

```
harnesses/shared/
  prompt-bodies/
    build.txt
    debug.txt
    refactor.txt
    shape.txt
```

Shared prompt body text files. At generate time, `generate.sh` concatenates `tools-header/<mode>.txt` + `prompt-bodies/<mode>.txt` to produce the final `<harness>-<mode>-system-prompt.txt`. This is the only directory shared between claude and pi at the harness level — everything else is harness-specific.

---

### `shared/`

```
shared/
  apps/             ← downstream AGENTS.md / PROJECT_CONTEXT templates
  recipes/          ← step-by-step implementation guides
  rules/            ← discipline rules (included in subagent templates)
  scaffold/         ← downstream app scaffold scripts + mutations
  subagents/        ← .md.j2 subagent templates
  usage_rules/      ← hex library usage rules
```

**Purpose**: Runtime artifacts — everything that gets installed or rendered into downstream project agents. Distinguished from `templates/` (generator pipeline and `.j2` sources for codegen infrastructure). When a new recipe, rule, or subagent template is needed, it goes in `shared/`.

#### `shared/apps/`

Templates and rendered copies for downstream project agent files.

| File                                  | Purpose                                                            |
| ------------------------------------- | ------------------------------------------------------------------ |
| `AGENTS-phoenix.md.j2`                | Jinja source — downstream `AGENTS.md` for Phoenix apps             |
| `AGENTS-phoenix.md`                   | Rendered reference copy (checked in; must stay in sync with `.j2`) |
| `AGENTS-static.md.j2`                 | Jinja source — downstream `AGENTS.md` for static sites             |
| `AGENTS-static.md`                    | Rendered reference copy for static sites                           |
| `CLAUDE-phoenix.md`                   | Downstream `CLAUDE.md` for Phoenix apps (plain file, not symlink)  |
| `CLAUDE-static.md`                    | Downstream `CLAUDE.md` for static sites                            |
| `PROJECT_CONTEXT-phoenix-template.md` | Format reference for downstream `PROJECT_CONTEXT.md`               |
| `PROJECT_CONTEXT-static-template.md`  | Format reference for static site `PROJECT_CONTEXT.md`              |

`codegen-scaffold` copies these into a new project directory during provisioning.

#### `shared/recipes/`

Step-by-step implementation guides for specific domain problems. Planners reference these by name in delegation prompts; subagents include them via `{% include %}` at generate time.

Naming convention: `<stack>-<topic>.md` (e.g., `phoenix-modal-js-animations.md`, `static-html-base-template.md`). Full catalog: `context/recipes.md`.

Do not add inline implementation code to recipes — describe the pattern and reference key modules. Recipes are read by AI agents, not executed.

#### `shared/rules/`

```
shared/rules/
  INDEX.md          ← registry: file → trigger keywords
  STYLE_GUIDE.md    ← cross-cutting style rules
  _core/
    bash-discipline.md
    cwd-discipline.md
    output-style.md
    session-log.md
  build-runtime/    ← rules specific to build-runtime behavior
  roles/
    committer.md
    context-curator.md
    developer.md
    orchestrator.md
    planner.md
    reviewer.md
  rules/            ← additional cross-cutting rules
  shared/           ← shared rule fragments
  stacks/
    phoenix/        ← Phoenix-specific rules
    static/         ← static site rules
```

Rules are `{% include %}`d into subagent `.md.j2` templates at generate time. Subagents do not read rules at runtime — they are baked in. To add a rule: write the `.md` file, add an `{% include %}` in the relevant `.md.j2` template(s), run `make install`.

| Directory         | Covers                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------- |
| `_core/`          | Universal rules for all agents: bash discipline, cwd discipline, output style, session log format |
| `build-runtime/`  | Rules specific to build-runtime behavior and edge cases                                           |
| `roles/`          | Per-role rules: what each agent is allowed/forbidden to do                                        |
| `shared/`         | Shared rule fragments referenced by multiple roles                                                |
| `stacks/phoenix/` | Phoenix/Elixir specific rules: testing, LiveView, developer pre-done checklist                    |
| `stacks/static/`  | Static site rules: Tailwind v4, Hugo, Vite, assets, JavaScript                                    |

Full domain: `context/rules-core.md`, `context/rules-roles.md`, `context/rules-stacks.md`.

#### `shared/scaffold/`

```
shared/scaffold/
  phoenix/
    README.md
    eex_render.sh
    scaffold.sh
    mutations/        ← per-file bash mutation scripts
    templates/        ← .eex source templates
  static/
    scaffold.sh
    scaffold_test.sh
```

Scaffolding scripts that `codegen-scaffold` delegates to. `scaffold.sh` creates the initial file tree for a new downstream project by running `mutations/` scripts (each writes one file) and `eex_render.sh` (renders `.eex` templates with variable substitution).

`scaffold_test.sh` is a bash test suite for the static scaffold; run via `make harness-parity`.

Full domain: `context/scaffold.md`.

#### `shared/subagents/`

```
shared/subagents/
  _phoenix_developer_common.md.j2   ← shared rules fragment (backend + frontend)
  _static_developer_common.md.j2    ← shared rules fragment (all static developers)
  phoenix/
    developer-phoenix-backend.md.j2
    developer-phoenix-frontend.md.j2
    planner-phoenix.md.j2
    reviewer-phoenix.md.j2
  static/
    developer-html.md.j2
    developer-hugo.md.j2
    developer-vite.md.j2
    planner-html.md.j2
    planner-hugo.md.j2
    planner-vite.md.j2
    reviewer-static.md.j2
  shared/
    committer.md.j2
    context-curator.md.j2
```

Jinja-style `.md.j2` templates. `generate.sh` renders these into per-harness agent prompt files installed to `~/.claude/agents/` or `~/.pi/agents/`. Each template uses `{% include %}` to inline rules, recipes, and common fragments — producing a fully self-contained system prompt baked at install time.

The two common fragments (`_phoenix_developer_common.md.j2`, `_static_developer_common.md.j2`) deduplicate rules shared by multiple developer roles in the same stack.

Full domain: `context/subagents.md`.

#### `shared/usage_rules/`

Hex library usage rules, one file per library-version (e.g., `phoenix_live_view-1.1.28.md`, `oban-2.21.1.md`). These are machine-generated summaries of library APIs and usage patterns, referenced by planners when authoring implementation plans.

`INDEX.md` maps library names to file paths and version coverage.

---

### `templates/`

```
templates/
  AGENTS-HYBRID.md.j2       ← source for root AGENTS.md + CLAUDE.md
  AGENTS-POC.md
  AGENTS.md                 ← rendered copy (pi render)
  CLAUDE.md                 ← rendered copy (claude render)
  CONTEXT.md
  NEW_PROMPT.md
  PROJECT_CONTEXT-MONOREPO.md
  PROJECT_CONTEXT.md
  RESUME_PROMPT.md
  context/
    core.md
    development.md
    pi-extensions/
  feature-workspace.code-workspace
  generator/                ← generator pipeline scripts
  mobile-Makefile
  monorepo-root-Makefile
  planning-sessions/
  recipes-README.md
  shared/
    pi-extensions/          ← pi-extension scaffold template
```

**Purpose**: Generator pipeline and `.j2` source templates for codegen infrastructure. Distinguished from `shared/` (runtime artifacts). Files here produce the infrastructure itself — agent files, hook registrations, scaffold templates.

#### `templates/AGENTS-HYBRID.md.j2`

The authoritative source for the root `AGENTS.md` and `CLAUDE.md`. Rendered by `make rule-parity` (diffed against committed files) and by `make install` (overwrites committed files). Contains Jinja conditionals for pi vs claude render paths.

Do not hand-edit `AGENTS.md` or `CLAUDE.md` at repo root — changes are overwritten by the next `make install`. Edit `templates/AGENTS-HYBRID.md.j2` instead.

#### `templates/generator/`

```
templates/generator/
  config.yaml               ← role → model/effort/tools mapping
  generate.sh               ← renders .md.j2 templates for a named harness
  generate-pi-extension.sh  ← scaffolds a new Pi extension from template
  hook_registrations.py     ← generates settings.json hook entries from hook source dir
  manifest-lib.sh           ← bash lib wrapping yq for manifest field extraction
  process_template.py       ← Jinja-style {% include %} processor
  test_dual_render.sh       ← self-test: renders both harnesses and diffs output
  test_fixtures/
    dual_render.md.j2       ← fixture template used by generator self-tests
```

| File                    | Purpose                                                                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `generate.sh`           | Entry — reads manifest, renders `.md.j2` templates into `templates/generated/<harness>/`                                             |
| `process_template.py`   | Jinja-style `{% include %}` processor; inlines rule/recipe files into subagent templates                                             |
| `hook_registrations.py` | Reads `harnesses/claude/hooks/*.sh`, generates hook entries in `claude-code-settings.json` and optionally into combobulate manifests |
| `config.yaml`           | Maps role names (planner-phoenix, developer-html…) to model IDs, effort levels, and tool configurations                              |
| `manifest-lib.sh`       | Bash library wrapping `yq` for structured manifest field access                                                                      |
| `test_dual_render.sh`   | Renders both harnesses from same templates, diffs output; catches template divergence between pi and claude                          |

Full domain: `context/core.md`.

#### `templates/shared/`

```
templates/shared/
  pi-extensions/    ← scaffold template for new Pi extensions
```

Scaffold template used by `generate-pi-extension.sh` when creating a new Pi extension. Provides `package.json`, `tsconfig.json`, and `src/` stub.

---

### `test_harness/`

```
test_harness/
  mix.exs
  test_helper.exs
  last_green.json
  record-green.sh
  lib/
    codegen_test_harness/
      assertions.ex
      fixtures.ex
  test/
    stacks/
      phoenix/      ← Phoenix scaffold ExUnit tests
      static/       ← Static scaffold ExUnit tests
```

**Purpose**: Elixir/ExUnit project that validates scaffold output and stack behavior end-to-end. Tests scaffold a fresh app using `codegen-scaffold`, run assertions on the generated code, and exercise real LLM build sessions through `codegen-build`. Not fast — these are the "does the whole system produce a working app?" gate.

| File                                     | Purpose                                                                              |
| ---------------------------------------- | ------------------------------------------------------------------------------------ |
| `mix.exs`                                | Elixir project definition — deps, test paths, mix aliases                            |
| `test/stacks/phoenix/`                   | ExUnit tests for Phoenix scaffold: compiles, seeds, routes, LiveView renders         |
| `test/stacks/static/`                    | ExUnit tests for static scaffold: builds, CSS emitted, HTML valid                    |
| `lib/codegen_test_harness/assertions.ex` | Shared assertion helpers used across stack tests                                     |
| `lib/codegen_test_harness/fixtures.ex`   | Fixture helpers for scaffold and generated output tests                              |
| `last_green.json`                        | Baseline: last commit SHA where full test suite passed; written by `record-green.sh` |
| `record-green.sh`                        | Writes `last_green.json` with current commit SHA + tool versions                     |

Run via `make test-stacks` (both harnesses, parallel partitions) or `make test-stacks-claude` / `make test-stacks-pi` individually. Full domain: `context/test-harness.md`.

---

### `node_modules/`

Root-level npm packages. Contains only `prettier` (declared in root `package.json`). Used by `make format`. Gitignored. Regenerate with `npm install` at repo root.

Do not add application packages here. Pi extension npm packages have their own `node_modules/` under `harnesses/pi/pi-extensions/<name>/`.

---

## Artifact Ownership and Update Triggers

| Artifact                                          | Owner                    | Updated by                                            | Trigger                                    |
| ------------------------------------------------- | ------------------------ | ----------------------------------------------------- | ------------------------------------------ |
| `harnesses/claude/claude-code-settings.json`      | Generator                | `hook_registrations.py`                               | `make install` or `make hook-parity`       |
| `harnesses/claude/claude-build-system-prompt.txt` | Generator                | `generate.sh`                                         | `make install`                             |
| `AGENTS.md` (repo root)                           | Template                 | `process_template.py` rendering `AGENTS-HYBRID.md.j2` | `make install`                             |
| `CLAUDE.md` (repo root)                           | Symlink                  | Created once by `install.sh`; points to `AGENTS.md`   | Never needs updating                       |
| `shared/` (all subdirs)                           | Contributors / curator   | Manual edit or context-curator subagent               | Feature development, learning accumulation |
| `context/*.md`                                    | Context curator          | `context-curator.md.j2` subagent + manual             | Post-reviewer in each dev cycle            |
| `codegen/logging/*.md`                            | Orchestrator + subagents | Session log write/edit during dev sessions            | Every dev cycle on THIS repo               |
| `test_harness/last_green.json`                    | CI / `record-green.sh`   | `make record-green` after `make test-all` passes      | Pre-deploy gate                            |
| `harnesses/pi/pi-extensions/*/node_modules/`      | npm                      | `npm install` in extension dir                        | After any `package.json` change            |
| Root `node_modules/`                              | npm                      | `npm install` at repo root                            | After `package.json` changes               |

---

## Cross-References

| Topic                                                  | File                                  |
| ------------------------------------------------------ | ------------------------------------- |
| Generator pipeline, manifest schema, install lifecycle | `context/core.md`                     |
| Harness launchers, dispatch, system prompt assembly    | `context/harnesses.md`                |
| Hook scripts, registration, lifecycle events           | `context/hooks.md`                    |
| Pi TypeScript extensions                               | `context/pi-extensions.md`            |
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

---

## Gaps and Clarifications

**`ai-agents/` status**: Directory exists but is orphaned. `install.sh` writes to `~/.claude/agents/`, not here. The empty `ai-agents/claude/commands/` path was an earlier design; ignore it.

**`codegen/` vs project `codegen/`**: The `codegen/` directory at repo root is THIS repo's own session log storage. Downstream projects (combobulate, etc.) each have their own `codegen/` at their root. These are entirely separate directory trees.

**`templates/AGENTS.md` and `templates/CLAUDE.md`**: These are rendered copies inside `templates/` (separate from root-level `AGENTS.md` and `CLAUDE.md`). They exist as reference snapshots. Root-level files are what `make install` distributes.

**`bin/test-llm-hooks.sh`**: The `bin/` name implies runnable utilities, but this file is a manual dev tool, not a CI script. It is not called by any Makefile target.

**Generated `*-system-prompt.txt` files**: Do not edit these. They are regenerated by `make install`. Source is `tools-header/` + `harnesses/shared/prompt-bodies/`. Hand edits are silently overwritten.

**`shared/usage_rules/` vs `shared/recipes/`**: Usage rules are machine-generated library API summaries (hex packages). Recipes are hand-authored implementation patterns. Different audiences: usage rules orient on API surface; recipes encode proven implementation sequences.

**Root `index.html`**: This is a test fixture, not a website. It exists so `test_harness/test/stacks/static/` tests can assert on static-site build output without needing a full downstream project.

---

## Trigger Keywords

repo layout, directory structure, where does X go, file tree, top-level files, codegen root, which directory, where to add, artifact location, file organization, repo anatomy, ocg vs codegen-build, ai-agents orphaned, self-meta codegen/, codegen/logging, context vs templates, shared vs templates, bin/ utilities, CLAUDE.md symlink, AGENTS.md source

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
