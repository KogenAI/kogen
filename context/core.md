# Core Domain — Manifest + Generator Pipeline

The core domain owns the manifest schema, generator pipeline, and install/uninstall lifecycle. Every harness is described by a `manifest.yaml`; `generate.sh` renders agent prompts from `.md.j2` templates; `install.sh` reads the manifest and runs declared install steps.

Data flow: `manifest.yaml` → `generate.sh` (renders via `process_template.py`) → `templates/generated/<harness>/` → `install.sh` → `~/.claude/` or `~/.pi/`.

## Key Modules

| Module                                      | Purpose                                                                                                                                        |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `templates/generator/generate.sh`           | Entry — renders `.md.j2` templates for a named harness                                                                                         |
| `templates/generator/process_template.py`   | Jinja-style `{% include %}` processor; inlines rule/recipe files                                                                               |
| `templates/generator/hook_registrations.py` | Generates `settings.json` hook entries from hook source dir                                                                                    |
| `templates/generator/enforcement_compiler.py` | Generates enforcement hook scripts (bash + TS) from `shared/enforcement/registry.yaml`                                                        |
| `templates/generator/manifest-lib.sh`       | Bash lib wrapping `yq` for manifest field extraction                                                                                           |
| `templates/generator/config.yaml`           | Role → model/effort/tools mapping; read by `load-role.sh`                                                                                      |
| `templates/generator/test_dual_render.sh`   | Self-test: renders both harnesses and diffs output for regressions                                                                             |
| `templates/generator/test_fixtures/`        | Fixture `.md.j2` templates used by generator self-tests                                                                                        |
| `harnesses/claude/manifest.yaml`            | Claude harness install contract (agents, hooks, launchers, modes)                                                                              |
| `harnesses/pi/manifest.yaml`                | Pi harness install contract                                                                                                                    |
| `install.sh`                                | Hardcoded per-harness install via case statement (line 260); reads manifest for step names                                                     |
| `uninstall.sh`                              | Removes artifacts listed in manifest uninstall_steps                                                                                           |
| `codegen-build`                             | Top-level launcher: requires --harness flag; delegates to harnesses/<harness>/dispatch.sh, which execs claude/pi with model/effort/tools flags |
| `codegen-scaffold`                          | Downstream app scaffolder: renders `shared/scaffold/` templates into a new project dir                                                         |
| `codegen-call`                              | One-shot structured LLM call binary: requires --harness, --role, --model, --effort, --system-prompt                                            |
| `config.sh`                                 | Shared env/path config sourced by all scripts                                                                                                  |
| `resource_manager.sh`                       | Manages port allocation across OCG projects system-wide via ~/.ocg/resources.json                                                              |
| `utils.sh`                                  | Common bash utilities: OCG_CMD invocation, open_cursor_workspace                                                                               |
| `update_ai_tools.sh`                        | Post-install: updates Claude CLI and AI tool deps                                                                                              |

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
codegen-call
config.sh
resource_manager.sh
utils.sh
update_ai_tools.sh
```

## Top-Level Launchers

Three entry-point scripts at repo root — each serves a distinct invocation context:

| Launcher           | Purpose                                                                                                                                                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `codegen-build`    | Default agent build launcher — requires `--harness` flag (exits 2 if absent); delegates to `harnesses/<harness>/dispatch.sh`, which execs `claude` or `pi` directly with model/effort/tools flags           |
| `codegen-scaffold` | Downstream app scaffolder — two subcommands: `codegen-scaffold create --stack=... --cwd=... --slug=...` (full scaffold) and `codegen-scaffold integrate --stack=... --cwd=... [--slug=...]` (symlinks only) |
| `codegen-call`     | One-shot structured LLM call binary — requires `--harness`, `--role`, `--model`, `--effort`, `--system-prompt @<path>`; used for non-build single calls                                                     |

Routing flow: `codegen-build` → `harnesses/<harness>/dispatch.sh` → reads `config.yaml` directly via `yq` (NOT via `load-role.sh`) → execs launcher with model/effort/tools flags. `load-role.sh` is used only by debug/shape/refactor/ops launchers, not build dispatch.

## Enforcement Compiler

`templates/generator/enforcement_compiler.py` generates enforcement hook scripts from a declarative registry (`shared/enforcement/registry.yaml`). Each registry entry becomes a pair of generated hooks — Bash (`.sh`) and TypeScript (`.ts`) — deployed to harness hook directories.

### Compiler Axes

**Source axis** — what the guard pattern matches:
- `source: COMMAND` — matches the bash command being executed
- `source: FILE_PATH` — matches the file path argument to Write/Edit

**Mode axis** — matching logic:
- `mode: deny` (default) — if pattern matches → deny; default is pass-through
- `mode: allowlist` — if pattern does NOT match → deny; default is allow; valid for both COMMAND and FILE_PATH sources

**Role axis** — scope by agent:
- `signal: AGENT_TYPE` — gate-guard on `$CLAUDE_ROLE` or `$PI_ROLE`; check proceeds only for listed role(s)
- `bypass_roles: [list]` — launcher-mode values (debug, shape, ops, …) that exit 0 immediately before role/match gates (from `resolve_role()` which folds `CLAUDE_ROLE > PI_ROLE`); emits prelude sourcing `_role.sh` (bash) or env-reading process.env (TS); placement: after `parse_input`, before AGENT_TYPE gate

### Template Forms

| Source | Mode | Body Template | Role Gate |
| ------ | ---- | ------------- | --------- |
| COMMAND | deny | `if grep -qE '<pattern>' <<< "$COMMAND"; then deny; fi` | AGENT_TYPE guard wraps entire body |
| COMMAND | allowlist | `if grep -qE '<pattern>' <<< "$COMMAND"; then exit 0; fi; deny` | AGENT_TYPE guard wraps entire body |
| FILE_PATH | allowlist | Multi-tool switch (Write/Edit); each arm: `if grep -qE '<pattern>' <<< "$FILE_PATH"; then exit 0; fi` | AGENT_TYPE guard wraps entire body |

All forms compose with `bypass_roles` prelude (if specified): the bypass exits early, skipping both role and match gates.

### Registry Fields

| Field | Type | Purpose | Default |
| ----- | ---- | ------- | ------- |
| `id` | string | Hook filename slug (kebab-case) | — |
| `generated` | bool | Compiler owns the output; `make install` regenerates it | — |
| `event` | string | Hook event (PreToolUse, SubagentStop, Stop) | — |
| `source` | string | COMMAND or FILE_PATH | COMMAND |
| `mode` | string | deny or allowlist | deny |
| `tool_guard` | string | Tool name (Bash, Write, Edit, …) | — |
| `match` | string | Single regex-neutral pattern (mutually exclusive with `match_all`) | — |
| `match_all` | list | AND-logic pattern list (mutually exclusive with `match`) | — |
| `message` | string | Denial reason shown to agent | — |
| `signal` | string | Hook signal (none, AGENT_TYPE, …) | none |
| `role` | string | Role scope: `*` (all) or pipe-separated (e.g., committer\|reviewer) | `*` |
| `bypass_roles` | list | Launcher-mode values (debug, shape, ops) that exit before gates | — |
| `harnesses` | string | Deployment target (all, claude, pi) | all |
| `canonicalize` | string | Path canonicalization (repo_relative); FILE_PATH only | — |

### Pattern Dialect

Registry patterns use dialect-neutral syntax; compiler translates to target:

| Pattern | Bash (ERE) | JavaScript |
| ------- | ---------- | ---------- |
| `\s` | `[[:space:]]` | `\s` (pass-through) |
| `\b` | `\b` | `\b` |
| `(a\|b)` | `(a\|b)` | `(a\|b)` |

FORBIDDEN: backreferences (`\1`, `\2`), lookahead/lookbehind (`(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`).

### Installation Workflow

1. `make install` → runs `enforcement_compiler.py`
2. Compiler reads `shared/enforcement/registry.yaml`
3. For each entry with `generated: true`, emits:
   - Bash hook → `harnesses/claude/hooks/<id>.sh` (chmod +x)
   - TypeScript hook → `harnesses/pi/pi-extensions/enforcement/src/hooks/<id>.ts`
4. Compiler invokes `_update_index()` to update Pi `index.ts` GENERATED block with new hook imports + registrations
5. `hook_registrations.py` rescans hook source dirs and rewrites `claude-code-settings.json` + pi manifest entries
6. Committed generated files must be byte-identical to compiler output → `make enforce-registry-parity` gate (part of `make test`) verifies this

## Manifest Schema

Each harness declares its full installation contract in `harnesses/<harness>/manifest.yaml`. This is the single source of truth for install behavior — `install.sh` and `uninstall.sh` read it to drive every step.

| Field             | Type   | Purpose                                                                                                           |
| ----------------- | ------ | ----------------------------------------------------------------------------------------------------------------- |
| `harness`         | string | Harness identifier (`claude`, `pi`)                                                                               |
| `agents_dir`      | path   | Install destination for rendered agent `.md` files                                                                |
| `generator`       | path   | Script that renders `.md.j2` templates → agent files                                                              |
| `settings_file`   | path   | Target settings JSON on developer machine                                                                         |
| `settings_source` | path   | Source settings JSON in repo                                                                                      |
| `hooks_dir`       | path   | Install destination for hook scripts                                                                              |
| `hooks_source`    | path   | Source hook scripts directory                                                                                     |
| `launchers`       | list   | `{name, src}` pairs — scripts symlinked/copied to `$INSTALL_DIR`                                                  |
| `completions`     | list   | Zsh completion script names to install                                                                            |
| `modes`           | map    | Per-mode config: `model`, `effort`, `output_format`, `tools`, `system_prompt_file`, `tools_header`, `prompt_body` |
| `install_steps`   | list   | Ordered install phases executed by `install.sh`                                                                   |
| `uninstall_steps` | list   | Ordered removal phases executed by `uninstall.sh`                                                                 |

## Repo-Root Artifact Ownership

Several scripts and dirs at repo root are owned or managed by the core pipeline:

| Artifact             | Owner / Purpose                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `bin/`               | Developer utility scripts only — contains `bin/test-llm-hooks.sh`; NOT managed by `install.sh`; NOT symlinked to `$PATH` |
| `ai-agents/`         | Orphaned placeholder — `install.sh` writes agent files to `~/.claude/agents/`, not here                                  |
| `bash_completion.sh` | Zsh/Bash completions for codegen CLI commands — installed by `install.sh`                                                |
| `config.sh`          | Shared env config sourced by all scripts — single source for `CODEGEN_DIR`, `INSTALL_DIR`                                |

Note: if a root-level artifact's ownership is unclear, check `resource_manager.sh` which tracks the installed-by-ocg manifest.

## Integration Points

- **harnesses**: manifest.yaml per harness is the single source of truth; core scripts read it to drive install
- **subagents**: `generate.sh` renders `shared/subagents/**/*.md.j2` into `templates/generated/<harness>/` agent files
- **hooks**: `hook_registrations.py` reads `harnesses/<harness>/hooks/` and writes `settings.json` entries
- **scaffold**: `codegen-scaffold` delegates to `shared/scaffold/<stack>/scaffold.sh`
- **test-harness**: ExUnit tests validate the rendered output and scaffold behaviour end-to-end

## Architectural Constraints

**One-way knowledge boundary**: Codegen MUST NOT know about, name, or validate downstream consumer projects. Codegen installs artifacts into `~/.claude/` and `~/.pi/` only; if a consumer symlink is stale or if the consumer's own setup validation fails, that failure happens in the consumer's build (the right place). Codegen does not own consumer validation. This keeps codegen focused on generator mechanics and prevents coupling to downstream-specific paths or concerns. Any cross-consumer validation logic (e.g. drift-guard) violates this boundary and should be removed.

## Update When Changing

Load this file when touching: `manifest.yaml`, `generate.sh`, `process_template.py`, `hook_registrations.py`, `enforcement_compiler.py`, `install.sh`, `uninstall.sh`, `codegen-build`, `codegen-scaffold`, `config.sh`, `resource_manager.sh`, `utils.sh`, or `shared/enforcement/registry.yaml`.
