# Core Domain — Manifest + Generator Pipeline

The core domain owns the manifest schema, generator pipeline, and install/uninstall lifecycle. Every harness is described by a `manifest.yaml`; `generate.sh` renders agent prompts from `.md.j2` templates; `install.sh` reads the manifest and runs declared install steps.

Data flow: `manifest.yaml` → `generate.sh` (renders via `process_template.py`) → `templates/generated/<harness>/` → `install.sh` → `~/.claude/` or `~/.pi/`.

## Key Modules

| Module                                    | Purpose                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------- |
| `templates/generator/generate.sh`         | Entry — renders `.md.j2` templates for a named harness                  |
| `templates/generator/process_template.py` | Jinja-style `{% include %}` processor; inlines rule/recipe files        |
| `templates/generator/hook_registrations.py` | Generates `settings.json` hook entries from hook source dir           |
| `templates/generator/manifest-lib.sh`     | Bash lib wrapping `yq` for manifest field extraction                    |
| `templates/generator/config.yaml`         | Role → model/effort/tools mapping; read by `load-role.sh`               |
| `templates/generator/test_dual_render.sh` | Self-test: renders both harnesses and diffs output for regressions      |
| `templates/generator/test_fixtures/`      | Fixture `.md.j2` templates used by generator self-tests                 |
| `harnesses/claude/manifest.yaml`          | Claude harness install contract (agents, hooks, launchers, modes)       |
| `harnesses/pi/manifest.yaml`              | Pi harness install contract                                             |
| `install.sh`                              | Manifest-driven install loop; calls per-step functions                  |
| `uninstall.sh`                            | Removes artifacts listed in manifest uninstall_steps                    |
| `codegen-build`                           | Top-level launcher: auto-detects harness type, routes to claude-build or pi-build |
| `codegen-scaffold`                        | Downstream app scaffolder: renders `shared/scaffold/` templates into a new project dir |
| `config.sh`                               | Shared env/path config sourced by all scripts                           |
| `resource_manager.sh`                     | Tracks installed-by-ocg manifest; prevents orphaned artifacts           |
| `utils.sh`                                | Common bash utilities: logging, `content_stable_cp`, path helpers       |
| `update_ai_tools.sh`                      | Post-install: updates Claude CLI and AI tool deps                       |

## Key Paths

```
harnesses/<harness>/manifest.yaml        ← install contract
templates/generator/generate.sh          ← render entry point
templates/generator/process_template.py  ← template processor
templates/generator/hook_registrations.py
templates/generator/manifest-lib.sh
templates/generator/config.yaml
templates/generator/test_dual_render.sh  ← generator self-test
templates/generator/test_fixtures/       ← self-test fixtures
install.sh
uninstall.sh
codegen-build
codegen-scaffold
config.sh
resource_manager.sh
utils.sh
update_ai_tools.sh
```

## Top-Level Launchers

Three entry-point scripts at repo root — each serves a distinct invocation context:

| Launcher          | Purpose                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `codegen-build`   | Default agent build launcher — auto-detects harness type, routes to `claude-build.sh` or `pi-build.sh` via harness `dispatch.sh` |
| `codegen-scaffold` | Downstream app scaffolder — invoked as `codegen-scaffold <stack> <output-dir>`; renders `shared/apps/` and `shared/scaffold/` templates into target directory |

Routing flow: `codegen-build` → detects harness → `harnesses/<harness>/dispatch.sh` → reads `config.yaml` via `load-role.sh` → execs launcher with model/effort/tools flags.

## Manifest Schema

Each harness declares its full installation contract in `harnesses/<harness>/manifest.yaml`. This is the single source of truth for install behavior — `install.sh` and `uninstall.sh` read it to drive every step.

| Field             | Type   | Purpose                                                                              |
| ----------------- | ------ | ------------------------------------------------------------------------------------ |
| `harness`         | string | Harness identifier (`claude`, `pi`)                                                  |
| `agents_dir`      | path   | Install destination for rendered agent `.md` files                                   |
| `generator`       | path   | Script that renders `.md.j2` templates → agent files                                 |
| `settings_file`   | path   | Target settings JSON on developer machine                                            |
| `settings_source` | path   | Source settings JSON in repo                                                         |
| `hooks_dir`       | path   | Install destination for hook scripts                                                 |
| `hooks_source`    | path   | Source hook scripts directory                                                        |
| `launchers`       | list   | `{name, src}` pairs — scripts symlinked/copied to `$INSTALL_DIR`                     |
| `completions`     | list   | Zsh completion script names to install                                               |
| `modes`           | map    | Per-mode config: `model`, `effort`, `output_format`, `tools`, `system_prompt_file`, `tools_header`, `prompt_body` |
| `install_steps`   | list   | Ordered install phases executed by `install.sh`                                      |
| `uninstall_steps` | list   | Ordered removal phases executed by `uninstall.sh`                                    |

## Repo-Root Artifact Ownership

Several scripts and dirs at repo root are owned or managed by the core pipeline:

| Artifact              | Owner / Purpose                                                              |
| --------------------- | ---------------------------------------------------------------------------- |
| `bin/`                | Compiled or generated launcher binaries — managed by `install.sh`            |
| `ai-agents/`          | Agent prompt output landing zone (may mirror `templates/generated/`)         |
| `bash_completion.sh`  | Zsh/Bash completions for codegen CLI commands — installed by `install.sh`    |
| `config.sh`           | Shared env config sourced by all scripts — single source for `CODEGEN_DIR`, `INSTALL_DIR` |

Note: if a root-level artifact's ownership is unclear, check `resource_manager.sh` which tracks the installed-by-ocg manifest.

## Integration Points

- **harnesses**: manifest.yaml per harness is the single source of truth; core scripts read it to drive install
- **subagents**: `generate.sh` renders `shared/subagents/**/*.md.j2` into `templates/generated/<harness>/` agent files
- **hooks**: `hook_registrations.py` reads `harnesses/<harness>/hooks/` and writes `settings.json` entries
- **scaffold**: `codegen-scaffold` delegates to `shared/scaffold/<stack>/scaffold.sh`
- **test-harness**: ExUnit tests validate the rendered output and scaffold behaviour end-to-end

## Update When Changing

Load this file when touching: `manifest.yaml`, `generate.sh`, `process_template.py`, `hook_registrations.py`, `install.sh`, `uninstall.sh`, `codegen-build`, `codegen-scaffold`, `config.sh`, `resource_manager.sh`, `utils.sh`.
