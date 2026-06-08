# Core Domain — Manifest + Generator Pipeline

The core domain owns the manifest schema, generator pipeline, and install/uninstall lifecycle. Every harness is described by a `manifest.yaml`; `generate.sh` renders agent prompts from `.md.j2` templates; `install.sh` reads the manifest and runs declared install steps.

Data flow: `manifest.yaml` → `generate.sh` (renders via `process_template.py`) → `templates/generated/<harness>/` → `install.sh` → `~/.claude/` or `~/.pi/`.

## Key Modules

| Module                                        | Purpose                                                                                                                                        |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `templates/generator/generate.sh`             | Entry — renders `.md.j2` templates for a named harness                                                                                         |
| `templates/generator/process_template.py`     | Jinja-style `{% include %}` processor; inlines rule/recipe files                                                                               |
| `templates/generator/hook_registrations.py`   | Generates `settings.json` hook entries from hook source dir                                                                                    |
| `templates/generator/enforcement_compiler.py` | Generates enforcement hook scripts (bash + TS) from `shared/enforcement/registry.yaml`                                                         |
| `templates/generator/manifest-lib.sh`         | Bash lib wrapping `yq` for manifest field extraction                                                                                           |
| `templates/generator/config.yaml`             | Role → model/effort/tools mapping; read by `load-role.sh`                                                                                      |
| `templates/generator/test_dual_render.sh`     | Self-test: renders both harnesses and diffs output for regressions                                                                             |
| `templates/generator/test_fixtures/`          | Fixture `.md.j2` templates used by generator self-tests                                                                                        |
| `harnesses/claude/manifest.yaml`              | Claude harness install contract (agents, hooks, launchers, modes)                                                                              |
| `harnesses/pi/manifest.yaml`                  | Pi harness install contract                                                                                                                    |
| `install.sh`                                  | Hardcoded per-harness install via case statement (line 260); reads manifest for step names                                                     |
| `uninstall.sh`                                | Removes artifacts listed in manifest uninstall_steps                                                                                           |
| `codegen-build`                               | Top-level launcher: requires --harness flag; delegates to harnesses/<harness>/dispatch.sh, which execs claude/pi with model/effort/tools flags |
| `codegen-scaffold`                            | Downstream app scaffolder: renders `shared/scaffold/` templates into a new project dir                                                         |
| `codegen-call`                                | One-shot structured LLM call binary: requires --harness, --role, --model, --effort, --system-prompt                                            |
| `config.sh`                                   | Shared env/path config sourced by all scripts                                                                                                  |
| `resource_manager.sh`                         | Manages port allocation across OCG projects system-wide via ~/.ocg/resources.json                                                              |
| `utils.sh`                                    | Common bash utilities: OCG_CMD invocation, open_cursor_workspace                                                                               |
| `update_ai_tools.sh`                          | Post-install: updates Claude CLI and AI tool deps                                                                                              |

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

`templates/generator/enforcement_compiler.py` generates enforcement hook scripts from a declarative registry (`shared/enforcement/registry.yaml`). Two entry kinds:

- **`kind: denial`** (default when `kind` absent) — generates ENTIRE `.sh`/`.ts` files (header + body). `generated: true` means `make install` OVERWRITES the whole file. Only 5 CLAUDE `.sh` files are owned this way.
- **`kind: registration`** — does NOT generate any file body. Header-only: `hook_registrations.py --emit-headers` reads these entries and injects the `# HOOK-MANIFEST:` block into the existing hand-written `.sh`, leaving body bytes identical. 45 behavioral hooks use this path.

Both kinds coexist in `shared/enforcement/registry.yaml`. The compiler skips `kind: registration` entries entirely — they have no `match`/`message` and are not denial rules.

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

| Source    | Mode      | Body Template                                                                                         | Role Gate                          |
| --------- | --------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------- |
| COMMAND   | deny      | `if grep -qE '<pattern>' <<< "$COMMAND"; then deny; fi`                                               | AGENT_TYPE guard wraps entire body |
| COMMAND   | allowlist | `if grep -qE '<pattern>' <<< "$COMMAND"; then exit 0; fi; deny`                                       | AGENT_TYPE guard wraps entire body |
| FILE_PATH | allowlist | Multi-tool switch (Write/Edit); each arm: `if grep -qE '<pattern>' <<< "$FILE_PATH"; then exit 0; fi` | AGENT_TYPE guard wraps entire body |

All forms compose with `bypass_roles` prelude (if specified): the bypass exits early, skipping both role and match gates.

### Registry Fields

| Field          | Type   | Purpose                                                                                                                                 | Default  |
| -------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `id`           | string | Hook filename slug (kebab-case)                                                                                                         | —        |
| `kind`         | string | `denial` (full-file generation) or `registration` (header-only injection)                                                               | `denial` |
| `generated`    | bool   | Compiler owns the output; `make install` regenerates it. Only valid for `kind: denial`                                                  | —        |
| `event`        | string | Hook event (PreToolUse, SubagentStop, Stop)                                                                                             | —        |
| `source`       | string | COMMAND or FILE_PATH                                                                                                                    | COMMAND  |
| `mode`         | string | deny or allowlist                                                                                                                       | deny     |
| `tool_guard`   | string | Canonical registry form; rendered to hook header as `matcher:`. Tool name (Bash, Write, Edit, …)                                        | —        |
| `match`        | string | Single regex-neutral pattern (mutually exclusive with `match_all`). Only for `kind: denial`                                             | —        |
| `match_all`    | list   | AND-logic pattern list (mutually exclusive with `match`). Only for `kind: denial`                                                       | —        |
| `message`      | string | Denial reason shown to agent. Only for `kind: denial`                                                                                   | —        |
| `signal`       | string | Hook signal (none, AGENT_TYPE, …)                                                                                                       | none     |
| `role`         | string | Role scope: `*` (all) or pipe-separated (e.g., committer\|reviewer)                                                                     | `*`      |
| `bypass_roles` | list   | Launcher-mode values (debug, shape, ops) that exit before gates                                                                         | —        |
| `harnesses`    | string | Canonical form: `claude` or `pi` (registry enum). Rendered to hook header as `claude_code` or `pi`. Deployment target (all, claude, pi) | all      |
| `rationale`    | string | Hook rationale text (optional, supports multi-line via YAML block scalar `\|`). For `kind: registration` only                           | —        |
| `canonicalize` | string | Path canonicalization (repo_relative); FILE_PATH only                                                                                   | —        |

### Pattern Dialect

Registry patterns use dialect-neutral syntax; compiler translates to target:

| Pattern  | Bash (ERE)    | JavaScript          |
| -------- | ------------- | ------------------- |
| `\s`     | `[[:space:]]` | `\s` (pass-through) |
| `\b`     | `\b`          | `\b`                |
| `(a\|b)` | `(a\|b)`      | `(a\|b)`            |

FORBIDDEN: backreferences (`\1`, `\2`), lookahead/lookbehind (`(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`).

### Installation Workflow

1. `make install` → runs `enforcement_compiler.py`
2. Compiler reads `shared/enforcement/registry.yaml`
3. For each `kind: denial` entry with `generated: true`, emits:
   - Bash hook → `harnesses/claude/hooks/<id>.sh` (chmod +x)
   - TypeScript hook → `harnesses/pi/pi-extensions/enforcement/src/hooks/<id>.ts`
4. Compiler invokes `_update_index()` to update Pi `index.ts` GENERATED block with new hook imports + registrations
5. **`hook_registrations.py --emit-headers` reads `kind: registration` entries → injects `# HOOK-MANIFEST:` header into each hand-written `.sh` (body unchanged).** CRITICAL: `render_header()` must NOT include a trailing `#` terminator line — `inject_header()` preserves the terminator from the original file body. Header span is injected idempotently via mktemp/cmp/mv.
6. `hook_registrations.py` rescans hook source dirs and rewrites `claude-code-settings.json` + pi manifest entries
7. Committed generated files must be byte-identical to compiler output → `make enforce-registry-parity` gate (part of `make test`) verifies this
8. Committed hook headers must match registry entries → `make hook-header-parity` gate (part of `make test`) verifies this

**Order dependency**: emit-headers (step 5) MUST run before hook-parity (step 6) so the settings generated from hook headers reflect the freshly-injected headers. Reversed order → stale settings.

### Header Injection Implementation Details

**`hook_registrations.py --emit-headers` and `--check-headers` modes:**

- `render_header(entry)` — builds the canonical `# HOOK-MANIFEST:` block from a `kind: registration` entry. **CRITICAL**: do NOT include a trailing `#` line in the rendered output — `inject_header()` preserves the file's original terminator (blank `#` or first non-`#` line). Including a terminator in the render causes apparent header drift on the first parity check.
- `inject_header(script_path, header_text)` — rewrites ONLY the header span (from `# HOOK-MANIFEST:` to the original terminator) in an existing hook script, leaving body bytes identical. Uses mktemp/cmp/mv for idempotency (re-running with unchanged input → no file touch).
- `--emit-headers` — injects freshly-rendered headers into all migrated hooks. Must run before `hook_registrations.py` default mode (step 6) to ensure settings are derived from the new headers.
- `--check-headers` — regenerates headers to /tmp and diffs vs committed `.sh` files. Used by `make hook-header-parity` gate to verify headers match the registry.
- Token mapping: registry stores `claude` (enum), but header field is `claude_code` (hook script format). Renderer maps `claude` → `claude_code` when emitting. Parser already accepts both via `VALID_HARNESSES = {"claude_code","pi"}` (line 66).
- Multi-line `rationale`: stored in registry as YAML block scalar (`|`); renderer emits `# rationale:` first line + `#   ` (indent) continuation lines. Parity diff catches any byte drift on round-trip.

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
