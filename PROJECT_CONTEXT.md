# codegen — Project Context

## Overview

- **What**: Meta-tooling repo that generates and installs AI-agent harnesses (Claude Code, Pi) into developer machines. Produces launcher scripts, hook systems, subagent prompt files, and scaffold templates consumed by downstream Phoenix and static-site projects.
- **Location**: `~/Areas/Optimum/codegen/` (dev) — installed artifacts land in `~/.claude/`, `~/.pi/`, and `/usr/local/bin/` (or `~/bin/`)
- **Stack**: Bash + Python (generator pipeline), TypeScript (Pi extensions), Elixir/ExUnit (test harness), Jinja2-like template rendering via `process_template.py`
- **Data flow**: `manifest.yaml` → `generate.sh` → rendered agent `.md` files → `install.sh` → `~/.claude/agents/`, hooks, launchers

## Domain Context Files

Load this index always. Load every row whose trigger matches the prompt. Files are small — loading 2–3 is cheap. Cost of a wrong-area read is one row; cost of a missing read is a stale plan. Hard cap: 6 rows.

| File                                  | Domain                                                                              | Load when prompt mentions...                                                                                                                                 | Update when changing...                                                                                                        |
| ------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `context/core.md`                     | Manifest + generator pipeline                                                       | manifest.yaml, generate.sh, harness install, install.sh, hook_registrations.py, codegen-build, codegen-scaffold                                              | harnesses/, install.sh, templates/generator/, generator scripts, manifest schema                                               |
| `context/harnesses.md`                | Claude + Pi harness specifics                                                       | claude-build, claude-debug, claude-shape, claude-refactor, pi-build, dispatch.sh, launcher, system prompt, modes, tools-header                               | harnesses/claude/, harnesses/pi/, launcher scripts, mode definitions, system-prompt-\*.txt                                     |
| `context/subagents.md`                | Subagent templates + roles                                                          | Planner, developer-phoenix-backend, developer-phoenix-frontend, developer-html/hugo/vite, reviewer, committer, .md.j2 template, agent rendering              | shared/subagents/, .md.j2 files, agent prompt bodies, rule includes in templates                                               |
| `context/rules-core.md`               | Core discipline rules                                                               | bash-discipline, output-style, session-log, cwd-discipline, STYLE_GUIDE, INDEX.md                                                                            | shared/rules/\_core/\*.md, shared/rules/INDEX.md, shared/rules/STYLE_GUIDE.md                                                  |
| `context/rules-roles.md`              | Role-specific behavioral rules                                                      | orchestrator rules, planner rules, developer rules, reviewer rules, committer rules, context-curator rules, never-implement, full-cycle, delegation          | shared/rules/roles/\*.md                                                                                                       |
| `context/rules-stacks.md`             | Stack-specific and cross-stack rules                                                | phoenix rules, static rules, git-readonly, config-single-source, hook-layering, LiveView patterns, ExUnit, Oban, migrations                                  | shared/rules/stacks/phoenix/_, stacks/static/_, shared/rules/shared/\*                                                         |
| `context/recipes.md`                  | Recipe catalog                                                                      | recipe, recipe INDEX, static-html-base-template, static-vite-scaffold, oban-job-rescheduling, mox-verify-on-exit-scope, elixir-context-test-structure        | shared/recipes/\*.md                                                                                                           |
| `context/subagent-influence-stack.md` | LLM subagent constraint layers & debugging                                          | subagent wrong behavior, influence stack, rule violation, system prompt, Jinja includes, rules baking, delegation prompt                                     | shared/rules/, CLAUDE.md, harnesses/\*/hooks/, .md.j2 templates, subagent templates                                            |
| `context/claude-token-mechanics.md`   | Token budgeting & prompt caching mechanics                                          | token mechanics, context window, cache, billing, Read cost, auto-compact, /context load, transcript JSONL                                                    | config.yaml, harnesses/\*/modes, templates/generator/, token budget thresholds                                                 |
| `context/claude-token-tuning.md`      | Token tuning & cost optimization per role                                           | token tuning, budget optimization, cost per role, Opus vs Haiku, Read discipline vs Bash grep                                                                | output-style.md, bash-discipline.md, config.yaml, harnesses/\*/modes                                                           |
| `context/hooks.md`                    | Hook system (bash + tests)                                                          | PreToolUse, SubagentStop, Stop hook, dev-gate.sh, phoenix-dev-gate.sh, hook test, run-tests.sh, gate verdict, hook registration                              | harnesses/\*/hooks/, hook scripts, hook tests (\_test.sh), hook_registrations.py                                               |
| `context/scaffold.md`                 | Scaffolding for downstream apps                                                     | scaffold.sh, eex_render, mutations, AGENTS.md.j2, PROJECT_CONTEXT.md.j2, ocg setup, downstream app scaffolding                                               | shared/scaffold/, .j2 template files, app scaffold templates, shared/apps/                                                     |
| `context/test-coverage.md`            | test coverage, coverage gaps, what tests exercise X, untested paths, test inventory | inventory of every executable surface in the repo + which test exercises it (or blank = work item)                                                           | context/test-coverage.md (self)                                                                                                |
| `context/test-harness.md`             | ExUnit test harness for stacks                                                      | test_harness, test-stacks, last_green, record-green.sh, stack scaffold test, ExUnit assertions                                                               | test_harness/, test fixtures, ExUnit tests (\*\_test.exs), last_green.json                                                     |
| `context/pi-extensions.md`            | Pi TypeScript extensions                                                            | pi-extension, askuserquestion, enforcement, web-utils, subagents extension, npm, TypeScript                                                                  | harnesses/pi/pi-extensions/, generate-pi-extension.sh, npm modules, TypeScript source files                                    |
| `context/development.md`              | Dev workflow + make targets                                                         | make install, make test, make test-stacks, CI/CD, Makefile, contribution, README, env vars                                                                   | Makefile, README.md, STYLE_GUIDE.md, .env.sample, CI workflows                                                                 |
| `context/repo-structure.md`           | Repository artifact ownership & structure                                           | ai-agents/, codegen/, bin/, index.html, ocg, codegen-build, codegen-scaffold, package.json, Makefile, root-level files, directory contents, artifact purpose | harnesses/, shared/, templates/, test_harness/, all top-level scripts, all top-level directories, .gitignore, Makefile changes |

## Generator Pipeline

| Module                                      | Purpose                                                                            |
| ------------------------------------------- | ---------------------------------------------------------------------------------- |
| `templates/generator/generate.sh`           | Entry point — renders `.md.j2` templates for a given harness                       |
| `templates/generator/process_template.py`   | Jinja-style `{% include %}` processor — inlines rule files into agent prompts      |
| `templates/generator/hook_registrations.py` | Writes `settings.json` hook entries from hook source dir                           |
| `templates/generator/manifest-lib.sh`       | Bash lib for parsing manifest YAML fields (wraps `yq`)                             |
| `templates/generator/config.yaml`           | Role/model/effort/tools mapping consumed by `load-role.sh`                         |
| `install.sh`                                | Manifest-driven install loop — reads manifest, runs install_steps                  |
| `uninstall.sh`                              | Removes installed artifacts listed in manifest                                     |
| `codegen-build`                             | Top-level launcher: picks harness, delegates to `claude-build.sh` or `pi-build.sh` |
| `codegen-scaffold`                          | Scaffolds a new downstream app from `shared/scaffold/` templates                   |
| `config.sh`                                 | Shared env/path config sourced by all scripts                                      |
| `resource_manager.sh`                       | Tracks installed-by-ocg manifest to avoid orphaned artifacts                       |
| `utils.sh`                                  | Common bash utilities (logging, content-stable copy, etc.)                         |
| `update_ai_tools.sh`                        | Updates Claude CLI and other AI tool deps after install                            |

## Integration Points

- **Downstream apps**: consume installed agents (`~/.claude/agents/*.md`), hooks (`~/.claude/hooks/*.sh`), and launchers (`claude-build`, `pi-build`) — not this repo directly
- **Claude Code**: hooks registered in `~/.claude/settings.json` via `hook_registrations.py`; agents discovered from `~/.claude/agents/`
- **Pi**: extensions compiled from TypeScript in `harnesses/pi/pi-extensions/`, installed to `~/.pi/`
- **test_harness**: ExUnit suite in `test_harness/` validates scaffold output — runs `mix test` against generated apps

## Environment Variables

| Variable             | Purpose                                      | Notes                   |
| -------------------- | -------------------------------------------- | ----------------------- |
| `CODEGEN_DIR`        | Absolute path to this repo                   | Set by launchers        |
| `INSTALL_DIR`        | Where launchers land (`/usr/local/bin` etc.) | Default: `~/bin`        |
| `ZSH_COMPLETION_DST` | Zsh completions install path                 | Set in `config.sh`      |
| `ANTHROPIC_API_KEY`  | Claude API key                               | Required for pi harness |
| `CLAUDE_MODEL`       | Override default model per mode              | Optional                |
