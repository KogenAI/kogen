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
| `harnesses/claude/dispatch.sh`                    | Mode dispatcher — reads manifest, sets flags, execs claude                                      |
| `harnesses/claude/load-role.sh`                   | Reads `config.yaml` to resolve model/effort/tools for a given role                              |
| `harnesses/claude/tools-header/`                  | Per-mode system prompt header fragments (build, debug, shape, ops)                              |
| `harnesses/claude/claude-code-settings.json`      | Source Claude Code settings (hooks, permissions, env)                                           |
| `harnesses/claude/claude-build-system-prompt.txt` | Generated (do not hand-edit) — concat of tools-header + prompt-body                             |
| `harnesses/claude/commands/`                      | Slash commands installed to `~/.claude/commands/`                                               |
| `harnesses/pi/pi-build.sh`                        | Pi build mode launcher                                                                          |
| `harnesses/pi/pi-debug.sh`                        | Pi debug mode launcher                                                                          |
| `harnesses/pi/pi-shape.sh`                        | Pi shape mode launcher                                                                          |
| `harnesses/pi/pi-ops.sh`                          | Pi ops mode launcher                                                                            |
| `harnesses/pi/dispatch.sh`                        | Pi mode dispatcher                                                                              |
| `harnesses/pi/pi-prompts/`                        | Pi-specific prompt fragments                                                                    |
| `harnesses/shared/prompt-bodies/`                 | Shared harness-agnostic body text (build, debug, shape, ops) — consumed by both harnesses       |
| `shared/prompt-fragments/`                        | Reusable prompt fragments included via `{% include %}` — `_probing.txt`, `_authoring-spine.txt` |
| `harnesses/claude/commands/`                      | Slash commands (`.md.j2` templates) installed to `~/.claude/commands/` at install time          |

## Key Paths

```
harnesses/claude/
  claude-build.sh, claude-debug.sh, claude-shape.sh, claude-ops.sh
  dispatch.sh, load-role.sh
  tools-header/{build,debug,shape,ops}.txt  ← disk path uses hyphen
  claude-code-settings.json
  claude-build-system-prompt.txt   ← generated
  commands/
harnesses/pi/
  pi-build.sh, pi-debug.sh, pi-shape.sh, pi-ops.sh
  dispatch.sh
  pi-prompts/
harnesses/shared/prompt-bodies/
  build.txt   ← Cycle Protocol + FIRST-TURN PROTOCOL body (shared between claude/pi)
  debug.txt   ← Protocol + Allowed Queries + Forbidden + Refusal & Pivot (shared between claude/pi)
  shape.txt   ← Cold-start + Pitch Readiness Check (shared between claude/pi)
  ops.txt     ← Rule 1-5 procedural ops rules (shared between claude/pi)
shared/prompt-fragments/
  _probing.txt         ← Inline Probe Discipline section (included in shape + /ready)
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

| Mode  | tools-header contains              | prompt_body list                                                     |
| ----- | ---------------------------------- | -------------------------------------------------------------------- |
| build | FIRST-TURN PROTOCOL + ## Tools     | [harnesses/shared/prompt-bodies/build.txt]                           |
| debug | mode description + ## Tools        | [harnesses/shared/prompt-bodies/debug.txt]                           |
| shape | mode title + ## Tools              | [shared/prompt-bodies/shape.txt, _probing.txt, _authoring-spine.txt] |
| ops   | mode title + Cold-Start + ## Tools | [harnesses/shared/prompt-bodies/ops.txt]                             |

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Per-harness vs shared bodies**: All modes (build, debug, ops, shape) use shared bodies from `harnesses/shared/prompt-bodies/`. Per-harness body directories no longer exist. shape additionally appends shared fragments (`_probing.txt`, `_authoring-spine.txt`). ssh cold-start context for debug/ops is launcher-injected via `--append-system-prompt`, not baked into the shared body.

**Shape investigative disciplines**: Shape mode includes the `_authoring-spine.txt` fragment, which encodes the readiness-loop gateway (Phase 0 context load → multi-turn investigation → readiness check). The spine enforces six core rules (A–F) — intent-guard, plain-language discipline, command-pairing auto-cover, duplication-detection, symptom-vs-target, context-drift auto-cover — and three deletion-safety blocker classes (un-investigated rabbit holes, untraced edit surface, dangling cross-reference). See `context/subagents.md` § Authoring Spine Rules for full details. The intent-guard rule (A) is additionally patched into the empirical-claim blocker template option-(b) in `shape.txt`, enforcing that no readiness-check option may nullify the pitch's core intent.

**Pitch-format contract**: `shape.txt` and `ops.txt` both specify the EXACT grammar for `## Questions` / `## Answers` blocks in headless mode. The contract is machine-parseable and enforced at Stop time by the `pitch-format-validator.sh` Stop hook (fires for shape/ops roles). Grammar: each `### Q<n>:` heading must be followed by ≥2 `- **<letter>)**` option bullets; `## Answers` Q-bindings must reference matching Q headings in `## Questions`; `> Status:` (if present) must be SKELETON, SHAPING, or SHAPED. The `/document` slash command writes `> Status: SKELETON` as the first line of every new skeleton pitch. Shape sessions advance the status to SHAPING (mid-investigation) or SHAPED (fully designed).

**Slash commands**: Templates in `harnesses/claude/commands/*.md.j2` (Jinja2) are rendered by `generate.sh` → `templates/generated/claude-code/commands/` → installed to `~/.claude/commands/` by `install.sh`. Commands can spawn subagent swarms (e.g., `/poke-holes` spawns Explore agents). Gating via `operator-subagent-allowlist.sh` enforces role ∈ {debug, shape, ops}. Examples: `/ready` (readiness gate), `/poke-holes` (stress-test pitch via Explore swarm). Pi gets an inert copy of all commands; no Pi-specific overrides yet.

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

## Headless Investigative Mode

The three Claude investigative launchers (`claude-shape`, `claude-ops`, `claude-debug`) honor the `CLAUDE_NONINTERACTIVE` env var. When set to any non-empty value, each launcher builds a `NON_INTERACTIVE_FLAGS` array containing the full 7-flag build set (byte-identical to `dispatch.sh`):

```
--print
--verbose
--output-format stream-json
--setting-sources project
--strict-mcp-config
--no-session-persistence
--disable-slash-commands
```

These flags are spliced as the **first positional** after `exec claude` (before `--model`). The env var name `CLAUDE_NONINTERACTIVE` intentionally diverges from `CODEGEN_BUILD_NON_INTERACTIVE` (dispatch) and `PI_NON_INTERACTIVE` (Pi).

**One-shot semantics**: headless investigative sessions run once and exit. There is no resume. If the agent needs a user decision (e.g., a pitch blocker in shape mode), it writes a `## Questions` block in the in-scope pitch file (permitted `codegen/pitches/` write) and stops. The operator answers out-of-band via a `## Answers` block; a fresh session continues.

**SSH launchers (ops, debug)**: before calling `resolve_ssh_target`, the launcher exports `SSH_TARGET_NON_INTERACTIVE=1` when `CLAUDE_NONINTERACTIVE` is set. `ssh-target.sh` reads this flag and exits 1 on alias miss instead of prompting — ensuring no interactive hang in headless mode.

## See Also

See `context/launcher-hook-matrix.md` for which orchestrator-level hooks gate each launcher mode (build vs debug/shape/refactor vs ops).

## Prompt-Hygiene Pattern: Spawn Ritual

**Ordering problem**: Models treat multi-step instructions (Edit → Agent) as separable; regression cause is treating them as alternatives (pick one).

**Solution**: Name the pair "spawn ritual" and phrase as ONE atomic operation in the prompt. Same wording appears in both `harnesses/{claude,pi}/tools-header/build.txt` (lines 14–16) → models treat header-Edit + delegation as indivisible. Hard enforcement via `step-log-section-before-spawn.sh` (PreToolUse guard denies subagent spawn if header absent).

**Reusable pattern for similar regressions**: When a prompt should enforce a strictly-ordered multi-step sequence, give it a memorable name (ritual, ceremony, protocol) and describe it as ONE conceptual operation. The name prevents decomposition into pick-one choices.

## Pitfalls

- **Never hand-edit `*-system-prompt.txt`** — generated by `manifest_regenerate_prompts()`; edits are overwritten on next `make install`
- **Mode tools lists** are canonical in `config.yaml` (not in manifest `modes` — manifest is documentation-of-record only)
- **`dispatch.sh` uses `COMMON_FLAGS` array** — under `set -u`, use `"${ARR[@]+"${ARR[@]}"}"` for empty-safe splicing
- **SP_FILE selection** — dispatch.sh must check `$NON_INTERACTIVE` before constructing prompt path; order matters (env var read must precede SP_FILE block)
- **Direct-build prompts are stack-gated** — pi-build-system-prompt-direct-phoenix.txt for Phoenix, -static.txt for static-site; dispatch.sh reads `$STACK` to select the correct file
- **prompt_body is a YAML sequence** — manifest's `prompt_body` is an ordered list, not a scalar; `manifest_regenerate_prompts()` iterates it; missing entries → non-zero exit (no partial prompt written)
- **Fragment paths** are relative to `CODEGEN_DIR` — `shared/prompt-fragments/_probing.txt` NOT `harnesses/shared/...`; process_template.py resolves `{% include %}` under `$CODEGEN_DIR/shared/`
- **ready.md.j2 is a template** — `harnesses/claude/commands/ready.md.j2` is rendered by `generate.sh` to `templates/generated/claude-code/commands/ready.md`; `install.sh` installs from generated dir; never install from source `.j2` directly
- **Spawn ritual wording** — identical in both harnesses (claude/pi `tools-header/build.txt` L14–16) because downstream agents inherit from both harnesses; edits to one must verify parity in the other. Second-to-land edits confirm by text match.
