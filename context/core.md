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
| `codegen-call`                                | One-shot structured LLM call binary: requires --harness (exits 2 if missing); unknown flags exit 2 (fail-loud); no --role flag                 |
| `config.sh`                                   | Shared env/path config sourced by all scripts                                                                                                  |
| `resource_manager.sh`                         | Manages port allocation across OCG projects system-wide via ~/.ocg/resources.json                                                              |
| `utils.sh`                                    | Common bash utilities: OCG_CMD invocation                                                                                                      |
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
| `codegen-call`     | One-shot structured LLM call binary — requires `--harness` (exits 2 if missing); unknown flags exit 2 (fail-loud); requires `--model`, `--effort`, `--system-prompt @<path>`; no --role flag                |

Routing flow: `codegen-build` → `harnesses/<harness>/dispatch.sh` → reads `config.yaml` directly via `yq` (NOT via `load-role.sh`) → execs launcher with model/effort/tools flags. `load-role.sh` is used only by debug/shape/refactor/ops launchers, not build dispatch.

Enforcement compiler (registry schema, pattern dialects, renderer-neutral tokens, install workflow): → see `context/enforcement-compiler.md`.

## Prompt-Body Duplication and Sibling Synchronization

When a pitch names N source files for extension but the load-bearing text is duplicated across (N+1) siblings that feed the SAME generated artifact, this is a **Rule-J parallel case**. Example: `shape.txt` extension to the Unverified-empirical-claims blocker also requires parallel updates to `_probing.txt` (same shape system prompt sink via `manifest.yaml` modes: `prompt_body = [shape.txt, _probing.txt, ...]`). Both files appear in the same rendered output; editing only the pitch-named N files leaves split-brain generated prompts.

**Treatment**: Include the (N+1)th sibling in the edit scope with a documented assumption of parallel scope widening. Do not silently honor the literal file-count constraint if it means shipping contradictory generated output.

**Parity-test sentinels**: the `prompt-content-parity_test.sh` file uses fixed-string grep assertions to verify baked prompt content. When extending a blocker like Unverified-empirical-claims with new probe lists or detection logic, audit whether sentinels exist for the old prose. If sentinels exist (e.g., `ASK-GATE: product forks only`, `INTERACTION-AUDIT: compose-check siblings`), confirm they still appear in the new blocker text. If no sentinels exist for the new rules (e.g., spread-technique or composition-check wording), no sentinel sync is required — parity coverage applies only to text already under test.

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

## Bidirectional Drift Auditing

When migrating hand-maintained hook wiring (e.g., pi `index.ts` registrations) to generated blocks, the change is NOT purely additive. Always audit both directions before widening the compiler's filter:

**Registry→Files**: which registry entries claim `harnesses: all|pi` but have NO corresponding `.ts` file? Over-claimed entries. The existence guard prevents broken imports, but the mismatch signals an incomplete migration (entry was declared before its pi twin was written). Normally transient; fix by writing the `.ts` or flipping harness back to `claude`.

**Files→Registry**: which `.ts` files exist but have registry `harnesses: claude`? Under-claimed entries — stale registry state. The compiler will NOT wire a `claude`-claimed hook even if a working pi twin exists. Fix by flipping the registry to `harnesses: all` and updating any stale rationale lines (e.g., "Agent tool not present in Pi harness" when a subagent matcher already exists).

Audit code can enumerate both directions with simple path/regex comparisons. Missing either direction → silent runtime breaks (unwired pi hooks or missing Claude hooks after filter widening).

## install.sh Shell Redirect Gotcha

When gating install steps with a subshell in `install.sh`, the shell construct `if (subshell) 2>&1` places the `2>&1` redirect on the **outer `if` compound command, not inside the subshell.** The redirect is a no-op; subshell stderr still flows to the terminal. Example: `if (npx playwright install chromium) 2>&1` captures NO output from playwright — redirect is applied after the `if` statement completes, not during subshell execution. Pattern: move the redirect INTO the subshell: `if (npx playwright install chromium 2>&1)` or use a separate context: `( npx playwright install chromium 2>&1 )` at the call site. This pitfall commonly appears in conditional Chromium installation steps (cf. session 20260608_153448).

## Stale Generated Artifacts

Some generated system-prompt files may become stale and stay in the repo as legacy:

- `claude-refactor-system-prompt.txt` / `pi-refactor-system-prompt.txt` — no corresponding `refactor` mode in `config.yaml` or manifest; no `system_prompt_file` points at them; NOT regenerated by `make install`. Safe to leave untouched; they are orphaned from earlier design. If deleting, verify no role-def templates or hooks reference them (should be zero hits in `grep -r` across `shared/` and `harnesses/`).

## Architectural Constraints

**One-way knowledge boundary**: Codegen MUST NOT know about, name, or validate downstream consumer projects. Codegen installs artifacts into `~/.claude/` and `~/.pi/` only; if a consumer symlink is stale or if the consumer's own setup validation fails, that failure happens in the consumer's build (the right place). Codegen does not own consumer validation. This keeps codegen focused on generator mechanics and prevents coupling to downstream-specific paths or concerns. Any cross-consumer validation logic (e.g. drift-guard) violates this boundary and should be removed.

(See `context/enforcement-compiler.md` for renderer-neutral regex tokens details.)

## Update When Changing

Load this file when touching: `manifest.yaml`, `generate.sh`, `process_template.py`, `hook_registrations.py`, `enforcement_compiler.py`, `install.sh`, `uninstall.sh`, `codegen-build`, `codegen-scaffold`, `config.sh`, `resource_manager.sh`, `utils.sh`, or `shared/enforcement/registry.yaml`.
