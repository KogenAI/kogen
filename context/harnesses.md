# Harnesses Domain — Claude + Pi Harness Specifics

The harnesses domain covers the per-harness launcher scripts, dispatch logic, mode definitions, system prompt assembly, and settings files. Each harness (Claude Code, Pi) has its own directory under `harnesses/` with a manifest, launcher scripts, system prompt `.txt` files, `tools-header/` fragments, and a `dispatch.sh` that selects mode and invokes the underlying CLI.

System prompt assembly: `tools-header/<mode>.txt` + each entry in `prompt_body[]` (ordered list from manifest) → concatenated by `manifest_regenerate_prompts()` into `<harness>-<mode>-system-prompt.txt`. The `prompt_body` list can have N entries; entries pointing to empty (0-byte) files are skipped.

## Components

| File / Dir                                        | Purpose                                                                                         |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `harnesses/claude/claude-build.sh`                | Launcher for build mode — sets model/effort, invokes `claude`                                   |
| `harnesses/claude/claude-debug.sh`                | Launcher for debug mode (Opus, high effort)                                                     |
| `harnesses/claude/claude-shape.sh`                | Launcher for shape mode (Opus, high effort, web tools enabled)                                  |
| `harnesses/claude/claude-ops.sh`                  | Launcher for ops mode (Opus, high effort)                                                       |
| `harnesses/claude/claude-refactor.sh`             | Launcher for refactor mode (Opus, high effort, web tools enabled)                               |
| `harnesses/claude/dispatch.sh`                    | Mode dispatcher — reads manifest, sets flags, execs claude                                      |
| `harnesses/claude/load-role.sh`                   | Reads `config.yaml` to resolve model/effort/tools for a given role                              |
| `harnesses/claude/tools-header/`                  | Per-mode system prompt header fragments (build, debug, shape, ops, refactor)                    |
| `harnesses/claude/claude-code-settings.json`      | Source Claude Code settings (hooks, permissions, env)                                           |
| `harnesses/claude/claude-build-system-prompt.txt` | Generated (do not hand-edit) — concat of tools-header + prompt-body                             |
| `harnesses/claude/commands/`                      | Slash commands installed to `~/.claude/commands/`                                               |
| `harnesses/pi/pi-build.sh`                        | Pi build mode launcher                                                                          |
| `harnesses/pi/pi-debug.sh`                        | Pi debug mode launcher                                                                          |
| `harnesses/pi/pi-shape.sh`                        | Pi shape mode launcher                                                                          |
| `harnesses/pi/pi-ops.sh`                          | Pi ops mode launcher                                                                            |
| `harnesses/pi/pi-refactor.sh`                     | Pi refactor mode launcher                                                                       |
| `harnesses/pi/dispatch.sh`                        | Pi mode dispatcher                                                                              |
| `harnesses/pi/pi-prompts/`                        | Pi-specific prompt fragments                                                                    |
| `harnesses/claude/prompt-bodies/`                 | Per-harness prompt body files for claude (build, debug, ops) — mode-specific non-tools content  |
| `harnesses/pi/prompt-bodies/`                     | Per-harness prompt body files for pi (build, debug, ops) — mode-specific non-tools content      |
| `harnesses/shared/prompt-bodies/`                 | Shared harness-agnostic body text (shape, refactor, plus shared ops rules)                      |
| `shared/prompt-fragments/`                        | Reusable prompt fragments included via `{% include %}` — `_probing.txt`, `_authoring-spine.txt` |

## Key Paths

```
harnesses/claude/
  claude-build.sh, claude-debug.sh, claude-shape.sh, claude-ops.sh, claude-refactor.sh
  dispatch.sh, load-role.sh
  tools-header/{build,debug,shape,ops,refactor}.txt  ← disk path uses hyphen
  claude-code-settings.json
  claude-build-system-prompt.txt   ← generated
  commands/
harnesses/pi/
  pi-build.sh, pi-debug.sh, pi-shape.sh, pi-ops.sh, pi-refactor.sh
  dispatch.sh
  pi-prompts/
harnesses/claude/prompt-bodies/
  build.txt   ← claude Cycle Protocol + FIRST-TURN PROTOCOL body
  debug.txt   ← claude debug Protocol + Allowed Queries + Forbidden etc.
  ops.txt     ← claude ops guardrails + server resolution + diagnostic workflow
harnesses/pi/prompt-bodies/
  build.txt   ← pi Step Queue Protocol + FIRST-TURN PROTOCOL body
  debug.txt   ← pi debug Protocol + Forbidden etc.
  ops.txt     ← pi ops guardrails + server resolution + diagnostic workflow
harnesses/shared/prompt-bodies/
  build.txt, debug.txt  ← empty (0 bytes, unused)
  shape.txt   ← Cold-start + Pitch Readiness Check (shared between claude/pi)
  refactor.txt ← Cold-start + Investigation depth + Pitch Readiness Check
  ops.txt     ← Rule 1-5 procedural ops rules (shared between claude/pi)
shared/prompt-fragments/
  _probing.txt         ← Inline Probe Discipline section (included in shape/refactor + /ready)
  _authoring-spine.txt ← Phase 0 (9-step), Multi-turn, Adjacent, Output Contract, Rules, Anti-patterns
```

## Prompt Assembly Layers

The `manifest_regenerate_prompts()` function assembles each mode prompt as:

```
tools-header/<mode>.txt   (per-harness: mode title + ## Tools + any pre-Tools content)
+ each entry in manifest prompt_body[]  (ordered list, empty entries skipped)
→ <harness>-<mode>-system-prompt.txt
```

**Mode assembly map:**

| Mode     | tools-header contains              | prompt_body list                                                          |
| -------- | ---------------------------------- | ------------------------------------------------------------------------- |
| build    | FIRST-TURN PROTOCOL + ## Tools     | [harnesses/<harness>/prompt-bodies/build.txt]                             |
| debug    | mode description + ## Tools        | [harnesses/<harness>/prompt-bodies/debug.txt]                             |
| shape    | mode title + ## Tools              | [shared/prompt-bodies/shape.txt, _probing.txt, _authoring-spine.txt]      |
| ops      | mode title + Cold-Start + ## Tools | [harnesses/<harness>/prompt-bodies/ops.txt, shared/prompt-bodies/ops.txt] |
| refactor | mode title + ## Tools              | [shared/prompt-bodies/refactor.txt, _probing.txt, _authoring-spine.txt]   |

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Per-harness vs shared bodies**: build/debug/ops have per-harness bodies (different content for claude vs pi). shape/refactor share bodies + fragments (content is identical between harnesses).

**`/ready` command**: `harnesses/claude/commands/ready.md.j2` — a Jinja2 template that `{% include 'prompt-fragments/_probing.txt' %}`. Rendered to `templates/generated/claude-code/commands/ready.md` by `generate.sh`, then installed from there by `install.sh`.

## Dispatcher Routing

`codegen-build` (see `context/core.md`) routes via `harnesses/<harness>/dispatch.sh`, which reads mode config and invokes the harness launcher:

```
claude-build.sh → codegen-build → harnesses/<harness>/dispatch.sh → execs claude-<mode>.sh / pi-<mode>.sh with model/effort/tools flags
```

For harness install contract details (agents_dir, hooks_dir, modes, launchers), see `harnesses/<harness>/manifest.yaml` documented in `context/core.md` Manifest Schema section.

## Integration Points

- **core**: manifest.yaml `modes` section documents model/effort/tools per mode; config.yaml is canonical source; for manifest schema see `context/core.md`
- **subagents**: system prompt files include rendered agent rules baked at generate time
- **hooks**: `claude-code-settings.json` is source for hook registration; `hook_registrations.py` writes the installed version; see `context/hooks.md`
- **pi-extensions**: Pi launchers invoke compiled TypeScript extensions from `harnesses/pi/pi-extensions/`

## Direct-Build Mode (Pi-Specific)

Pi harness supports two operational modes via `dispatch.sh` SP_FILE selection:

- **Interactive mode** (`pi-build.sh` manual launcher): Full orchestrator workflow (5-role chain), consumes `pi-build-system-prompt.txt`
- **Non-interactive mode** (`codegen-build --harness=pi --non-interactive`): Direct-build single-process agent, consumes `pi-build-system-prompt-direct-phoenix.txt` or `pi-build-system-prompt-direct-static.txt` (stack-gated)

Mode selection gated by `$NON_INTERACTIVE` env var (wired in `dispatch.sh:26`). Direct-build prompt forbids `mix phx.new` and orchestration vocabulary; app must be pre-scaffolded (fixture responsibility). Non-interactive mode removes subagents extension — skips the 5-role chain to fit within small-model token budget and internal timeout constraints. Test suite assertions only check compile + route + commit format — zero assertions on multi-agent artifacts.

## Pi Extensions

Pi launchers load TypeScript extensions from `harnesses/pi/pi-extensions/` via compiled modules. Extensions are versioned with the harness and provide task-specific logic (dispatch, hook bindings, snippet handling). Extensions are invoked via flags, not indirectly by launcher env — see `harnesses/pi/<mode>.sh` for extension invocation signatures.

## See Also

See `context/launcher-hook-matrix.md` for which orchestrator-level hooks gate each launcher mode (build vs debug/shape/refactor vs ops).

## Pitfalls

- **Never hand-edit `*-system-prompt.txt`** — generated by `manifest_regenerate_prompts()`; edits are overwritten on next `make install`
- **Mode tools lists** are canonical in `config.yaml` (not in manifest `modes` — manifest is documentation-of-record only)
- **`dispatch.sh` uses `COMMON_FLAGS` array** — under `set -u`, use `"${ARR[@]+"${ARR[@]}"}"` for empty-safe splicing
- **SP_FILE selection** — dispatch.sh must check `$NON_INTERACTIVE` before constructing prompt path; order matters (env var read must precede SP_FILE block)
- **Direct-build prompts are stack-gated** — pi-build-system-prompt-direct-phoenix.txt for Phoenix, -static.txt for static-site; dispatch.sh reads `$STACK` to select the correct file
- **prompt_body is a YAML sequence** — manifest's `prompt_body` is an ordered list, not a scalar; `manifest_regenerate_prompts()` iterates it; missing entries → non-zero exit (no partial prompt written)
- **Fragment paths** are relative to `CODEGEN_DIR` — `shared/prompt-fragments/_probing.txt` NOT `harnesses/shared/...`; process_template.py resolves `{% include %}` under `$CODEGEN_DIR/shared/`
- **ready.md.j2 is a template** — `harnesses/claude/commands/ready.md.j2` is rendered by `generate.sh` to `templates/generated/claude-code/commands/ready.md`; `install.sh` installs from generated dir; never install from source `.j2` directly
