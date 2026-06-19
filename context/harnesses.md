# Harnesses Domain — Claude + Pi Harness Specifics

The harnesses domain covers the per-harness launcher scripts, dispatch logic, mode definitions, system prompt assembly, and settings files. Each harness (Claude Code, Pi) has its own directory under `harnesses/` with a manifest, launcher scripts, system prompt `.txt` files, `tools-header/` fragments, and a `dispatch.sh` that selects mode and invokes the underlying CLI.

System prompt assembly: `tools-header/<mode>.txt` + each entry in `prompt_body[]` (ordered list from manifest) → concatenated by `manifest_regenerate_prompts()` into `<harness>-<mode>-system-prompt.txt`. The `prompt_body` list can have N entries; entries pointing to empty (0-byte) files are skipped.

## Components

| File / Dir                                        | Purpose                                                                                                                       |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `harnesses/claude/claude-build.sh`                | Launcher for build mode — sets model/effort, invokes `claude`                                                                 |
| `harnesses/claude/claude-debug.sh`                | Launcher for debug mode (Opus, high effort)                                                                                   |
| `harnesses/claude/claude-experiment.sh`           | Launcher for experiment mode (Opus, high, source-writable, `--worktree exp-<slug>`)                                           |
| `harnesses/claude/claude-shape.sh`                | Launcher for shape mode (Opus, high effort, web tools enabled)                                                                |
| `harnesses/claude/claude-ops.sh`                  | Launcher for ops mode (Opus, high effort)                                                                                     |
| `harnesses/claude/dispatch.sh`                    | Mode dispatcher — reads manifest, sets flags, execs claude                                                                    |
| `harnesses/claude/load-role.sh`                   | Reads `config.yaml` at runtime to resolve model/effort/tools for shape/ops/debug/experiment; not used by build (baked prompt) |
| `harnesses/claude/tools-header/`                  | Per-mode system prompt header fragments (build, debug, experiment, shape, ops)                                                |
| `harnesses/claude/claude-code-settings.json`      | Source Claude Code settings (hooks, permissions, env)                                                                         |
| `harnesses/claude/claude-build-system-prompt.txt` | Generated (do not hand-edit) — concat of tools-header + prompt-body                                                           |
| `harnesses/claude/commands/`                      | Slash commands installed to `~/.claude/commands/`                                                                             |
| `harnesses/pi/pi-build.sh`                        | Pi build mode launcher                                                                                                        |
| `harnesses/pi/pi-debug.sh`                        | Pi debug mode launcher                                                                                                        |
| `harnesses/pi/pi-experiment.sh`                   | Pi experiment mode launcher (no worktree; confinement = tool-allowlist + system prompt)                                       |
| `harnesses/pi/pi-shape.sh`                        | Pi shape mode launcher                                                                                                        |
| `harnesses/pi/pi-ops.sh`                          | Pi ops mode launcher                                                                                                          |
| `harnesses/pi/dispatch.sh`                        | Pi mode dispatcher                                                                                                            |
| `harnesses/pi/pi-prompts/`                        | Pi-specific prompt fragments                                                                                                  |
| `harnesses/shared/prompt-bodies/`                 | Shared harness-agnostic body text (build, debug, experiment, shape, ops) — consumed by both harnesses                         |
| `shared/prompt-fragments/`                        | Reusable prompt fragments included via `{% include %}` — `_probing.txt`, `_authoring-spine.txt`                               |
| `harnesses/claude/commands/`                      | Slash commands (`.md.j2` templates) installed to `~/.claude/commands/`                                                        |

## Dispatch & Session Re-Attach API

**Claude re-attach flag**: `claude --resume <id>` (full or partial UUID). Valueless `--resume` opens interactive session picker. Dispatch MUST emit `--resume "$id"` only when id is non-empty; never emit valueless flag.

**Pi re-attach flag**: `pi --session <path|id>` (full or partial UUID or file path). Pi has `--session-id <id>` which CREATES a new session if the id doesn't exist — wrong for re-attach (would silently start fresh on stale id). Always use `--session "$id"` for re-attach semantics (fails on stale id, correct error path). Dispatch MUST emit `--session "$id"` only when id is non-empty.

**One-shot launcher boundary**: `claude-ops.sh`, `claude-shape.sh`, `claude-debug.sh`, `call-dispatch.sh` are single-invocation launchers with UNCONDITIONAL `--no-session-persistence` (Claude) or `--no-session` (Pi). These must NOT read `CODEGEN_BUILD_RESUMABLE` or `CODEGEN_BUILD_RESUME_ID` environment variables. The boundary is clean: only `dispatch.sh` (called by `codegen-build`) reads resumable flags; one-shot launchers remain deterministic. Enforce via grep: variable names MUST NOT appear in launcher source files.

## Key Paths

```
harnesses/claude/
  claude-build.sh, claude-debug.sh, claude-experiment.sh, claude-shape.sh, claude-ops.sh
  dispatch.sh, load-role.sh
  tools-header/{build,debug,experiment,shape,ops}.txt  ← disk path uses hyphen
  claude-code-settings.json
  claude-build-system-prompt.txt   ← generated
  commands/
harnesses/pi/
  pi-build.sh, pi-debug.sh, pi-experiment.sh, pi-shape.sh, pi-ops.sh
  dispatch.sh
  pi-prompts/
harnesses/shared/prompt-bodies/
  build.txt      ← Cycle Protocol + FIRST-TURN PROTOCOL body (shared between claude/pi)
  debug.txt      ← Protocol + Allowed Queries + Forbidden + Refusal & Pivot (shared)
  experiment.txt ← single-agent, source-writable, worktree investigation (shared)
  shape.txt      ← Cold-start + Pitch Readiness Check (shared between claude/pi)
  ops.txt        ← Rule 1-5 procedural ops rules (shared between claude/pi)
shared/prompt-fragments/
  _probing.txt         ← Inline Probe Discipline section (included in shape + /ready)
  _authoring-spine.txt ← Phase 0 (9-step), Multi-turn, Adjacent, Output Contract, Rules, Anti-patterns
```

## Mode Launcher Cloning Pattern

Clone existing launcher: swap role name, log prefixes, mode-specific flags (e.g., `--worktree`). Two config blocks REQUIRED when Claude/Pi read different paths: `roles.<mode>` (load-role.sh) + `harness.<mode>.pi` (yq). NOT redundant — both committed. Update both manifests' `modes.<mode>` + launcher/completion registration + tools_header/prompt_body refs. All `.txt` files must pre-exist; `manifest_regenerate_prompts()` exits non-zero if missing.

## Completions Installation Path

Zsh completions (e.g., `_claude-experiment`) install from `harnesses/<harness>/_<name>` via manifest-driven loop (install.sh:696); fully manifest-controlled, no separate dir. Naming: underscore prefix required (`_claude-experiment`); `#compdef` names the context.

## Prompt Assembly Layers

The `manifest_regenerate_prompts()` function assembles each mode prompt as:

```
tools-header/<mode>.txt   (per-harness: mode title + ## Tools + any pre-Tools content)
+ each entry in manifest prompt_body[]  (ordered list, empty entries skipped)
→ <harness>-<mode>-system-prompt.txt
```

**Mode assembly map:**

| Mode  | tools-header contains (per-harness)                                                                                                        | prompt_body list (shared)                                                                                             |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| build | `## Tools` + harness-specific tool list + FIRST-TURN bullets + `## Cycle Protocol` / `## Step Queue Protocol`                              | [harnesses/shared/prompt-bodies/build.txt] — neutral tool-discipline lines, Commit Hygiene, shared FIRST-TURN bullets |
| debug | `## Tools` + harness-specific tool list + FORBIDDEN list + cross-repo grep allowance                                                       | [harnesses/shared/prompt-bodies/debug.txt] — no-cat-pipe line + Protocol + Forbidden + Refusal & Pivot                |
| shape | `## Tools` + harness-specific tool bullets (claude: Agent/Skill/AskUserQuestion/Write-Edit; pi: askuserquestion/subagents/web-utils names) | [shared/prompt-bodies/shape.txt, _probing.txt, _authoring-spine.txt] — mode-title + no-cat-pipe line                  |
| ops   | `## Tools` + harness-specific per-tool bullets                                                                                             | [harnesses/shared/prompt-bodies/ops.txt] — starts with Cold-Start Opening block, followed by procedural ops rules     |

**Placement checklist** — when deciding whether content belongs in the per-harness header or the shared body:

- **→ per-harness `tools-header/<mode>.txt`** (must differ between harnesses):
  - Tool names that differ between harnesses (e.g., claude `Agent` vs pi `subagents`, claude `Skill` vs pi omitted, claude `Write/Edit` vs pi `edit/write`)
  - Launcher flags and hook-capability differences (e.g., `orchestrator-no-source-edit.sh` claude hook path, `--tools` allowlist differences)
  - Install paths specific to one harness (e.g., `~/.claude/hooks/`, `~/.claude/settings.json` as enforcement investigation targets in the Tools section)
  - Per-harness protocol section names (`## Cycle Protocol` claude; `## Step Queue Protocol` pi)
  - Harness-specific ritual wording (`Agent()` ritual claude; `subagent()` ritual pi)
  - Harness-specific invocation sentence (`claude-build`/`pi-build`)
  - Harness-specific post-commit hook name (`.sh` vs `.ts`)

- **→ shared `harnesses/shared/prompt-bodies/<mode>.txt`** (identical across harnesses):
  - Neutral tool-usage discipline (no-cat-pipe, no-explore rules)
  - Orchestration discipline (session log creation bullets, context-curator naming rule)
  - Commit Hygiene block and WHY-handoff rules
  - Cold-start opening gates (ops: the `## Cold-Start Opening` confirm block)
  - Protocol/behavior sections that are harness-agnostic (headless mode, output style, forbidden actions)

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Per-harness vs shared bodies**: All modes use shared bodies from `harnesses/shared/prompt-bodies/`. Per-harness body directories no longer exist. shape additionally appends shared fragments (`_probing.txt`, `_authoring-spine.txt`). ssh cold-start context for debug/ops is launcher-injected via `--append-system-prompt`, not baked into the shared body.

**Sentinel and content propagation**: A sentinel added to any `prompt_body[]` file or appended fragment automatically propagates to the assembled baked prompt. Shape mode feeds two sources (`shape.txt` and `_authoring-spine.txt`); a sentinel in either reaches the final artifact. Distributed editing is safe: both occurrences land in the baked prompt (harmless duplication for a presence test).

**Shape investigative disciplines**: Shape mode includes the `_authoring-spine.txt` fragment, which encodes the readiness-loop gateway (Phase 0 context load → multi-turn investigation → readiness check). The spine enforces six core rules (A–F) — intent-guard, plain-language discipline, command-pairing auto-cover, duplication-detection, symptom-vs-target, context-drift auto-cover — and three deletion-safety blocker classes (un-investigated rabbit holes, untraced edit surface, dangling cross-reference). See `context/subagents.md` § Authoring Spine Rules for full details. The intent-guard rule (A) is additionally patched into the empirical-claim blocker template option-(b) in `shape.txt`, enforcing that no readiness-check option may nullify the pitch's core intent.

**Shaper ask-vs-decide classifier** (hardened): Ask user ONLY when the answer changes what the user experiences or names something the user owns — UX copy/flow/behavior, product-intent forks (build A vs B), or identity the user controls. Test for EVERY candidate question: "Does the answer change what the PRODUCT DOES — a genuine build-A-vs-build-B fork where the choice depends on intent the code cannot reveal?" If no → auto-decide. Never-ask set: which tool/model/library, machine/environment, how to process input, what a pitch commits to, directory/file placement, how to split, naming. Two further behaviors: (1) **answered-question memory** — scan conversation before any AskUserQuestion; already-answered OR deflected ("you decide", "why are you asking?") = binding answer (auto-decide, never re-ask); (2) **cold-start raw-material** — user arrives with audio/notes/brain-dump → shaper states one-line plan, reads material, splits into threads, writes one SKELETON pitch per thread into `codegen/pitches/draft/`. Engineering-completeness decisions auto-decide: install-guarantee (always yes), fail-closed-when-guaranteed (always yes once guaranteed), internal naming (follow repo convention), how to split (shaper reads code and decides) → record as `Assumed: <dimension> = <default> (override if wrong)`. Escape-hatch rule (step c' in shape.txt) enforces this at blocker-resolution time.

**SSH target resolution paths (ops/debug launchers)**: `resolve_ssh_target()` in `ssh-target.sh` has three distinct resolution outcomes: (1) **HIT** — candidate alias is found in `~/.ssh/config` as a defined Host; (2) **MISS-save** — user typed a bare IP that `ssh -G` cannot resolve; treat the IP as a new Host and save it to config under the candidate alias name; (3) **MISS-existing** — user typed an alias that IS defined in `~/.ssh/config` but differs from the candidate (user deliberately chose an existing alias, not the candidate). The connect alias MUST be different on the third path: use `$user_alias` (what the user typed, which IS a real Host), NOT `$candidate` (which has no defined Host block on this path). All three paths export `${prefix}_ALIAS` for consumption by launchers (debug/ops). When `${prefix}_ALIAS` is empty, fall back to `server_resolved` (bare IP) so the exported value is never empty and launcher self-check commands (`ssh ${DEBUG_ALIAS}`) remain well-formed. Tests assert the alias export on all three paths: `T-new-11` (HIT), `T-new-12` (MISS-save), `T-new-13` (MISS-existing).

**Per-harness header rewrite discipline (shape mode)**: Shape mode tools-headers were historically byte-identical clones for both harnesses, creating a "Claude-ism leak" in the Pi header. Pi shape-header rewrites must replace all Claude-specific vocabulary (tool names: `Agent`/`Skill`/`AskUserQuestion`/`Write`/`Edit`; hook paths like `~/.claude/hooks/`, `~/.claude/settings.json`; subagent references like `orchestrator-no-source-edit.sh`, `operator-subagent-allowlist.sh`, `launch Explore subagent`) with Pi-correct tool names and enforcement-extension references. Neutral lines (mode-title sentence, neutral tool-usage discipline) relocate to the shared `harnesses/shared/prompt-bodies/shape.txt`. If Pi has no functional equivalent for a clause line (e.g., `Skill` tool does not exist in Pi), omit it rather than copy Claude vocabulary. After rewrite, the two shape headers are no longer byte-identical, and neutral shared content appears once in the assembled prompt.

**Shared body relocation pitfall** — when moving lines from per-harness headers into shared bodies, avoid introducing NEW section headings that were not present in the source headers. Even a sensible heading name causes a line-set diff false positive that post-relocation equality assertions catch. Keep section headings in headers (they are structural, not prose), and move only prose lines. Example: `## FIRST-TURN PROTOCOL` stays in headers; the shared FIRST-TURN prose bullets move to the body. The heading structure itself remains per-harness.

**Fragment references in shared bodies** — `_authoring-spine.txt` legitimately references `~/.claude/settings.json` as a debugging target for enforcement-bug investigation (e.g., "if a hook file references `~/.claude/settings.json`..."). This is a SHARED investigative discipline (not Claude-specific), and is correct to appear in the Pi assembled prompt. The distinction: `~/.claude/hooks/` or `orchestrator-no-source-edit.sh` are Claude implementation details (remove from Pi header); `~/.claude/settings.json` as an inspection target is a cross-harness debugging pattern (keep in shared fragments).

**Deferral-with-draft contract**: Every deferral (any "deferred", "future work", "phase 2", "out of scope", "accepted risk", "cut-1", or "deferred to implementation") MUST be backed by a real `codegen/pitches/draft/<slug>.md` file. The pitch must reference the draft (e.g., "deferred — see draft `<slug>`"). A prose-only deferral with no draft file is a blocker, not a resolution. Security/safety-relevant deferrals (auth, access control, secret handling, data deletion, anything widening exposure) must additionally state the exposure assumption in the draft's rationale (e.g., "safe to defer only while the box is unreachable"). This contract prevents the failure mode that shipped incomplete features (no auth, missing validation, unhandled error paths).

**Decompose-then-split rule** (Rule G in spine): When a problem is too large for one focused build pass (spans multiple independent surfaces or requires prerequisites that don't exist yet), the shaper SPLITS it into N independently-buildable pitches ITSELF — it does NOT ask the user "should I split this?" or "how should I split this?". Splitting is an engineering-decomposition decision the shaper makes by reading the code and dependency structure. The ONLY split-related question that reaches the user is a genuine product fork the decomposition reveals (feature A vs feature B is the user's decision, not a mechanical decomposition decision). Emit one chat line naming what was split: `Decomposed: extracted pitches <slug-1>, <slug-2> …`. This generalizes Phase-0's dedup-extraction rule (Rule D).

**Derive-and-write dependency edges rule** (Rule H in spine): When splitting a pitch, the shaper DERIVES the build-order dependencies (which pitch must ship before which — by reading what each consumes that another produces) and WRITES them as `Blocks-on: <slug>` lines into each pitch's `## Dependencies` block (one slug per line). The dashboard topo-sorts these declared edges but performs zero inference of its own — an omitted edge silently mis-orders the queue. The shaper does NOT ask the user "what depends on what?" — it reads the code and derives the ordering. A circular or ambiguous dependency the shaper genuinely cannot resolve from code IS a legitimate AskUserQuestion; a derivable ordering is not. The `## Dependencies` block grammar is already shipped in `pitch-format-contract.md` (back-compat: `Blocks-on:` is also accepted inside `## Related pitches`). Every split MUST leave correct, parseable `## Dependencies` blocks behind.

## Multi-Pitch Protocol

Per-harness tools-headers now contain complete multi-pitch sequencing rules for handling multiple pitches in a single build invocation (`claude-build a b c` or `pi-build a b c`).

**Why per-harness**: Claude and Pi have different concurrency models (Claude cycles through planner/dev/gate/reviewer/curator/committer; Pi processes sequential step queues). The four-rule protocol is identical in INTENT but expressed in per-harness vocabularies to align with each harness's native concepts:

- **Claude** (`harnesses/claude/tools-header/build.txt` lines 37–41) — uses "cycle" and "pitch" vocabulary; sequences via `Cycle Protocol` section
- **Pi** (`harnesses/pi/tools-header/build.txt` lines 62–69) — uses "step queue" and "queue position" vocabulary; sequences via `Multi-pitch-file builds` subsection

**The four rules** (identical intent, harness-specific vocabulary):

1. **One session log per pitch** — each pitch file gets its own `<ts>_<slug>_session.md` log; never combine pitches.
2. **Strict sequencing** — complete the full cycle/queue for pitch[i] (including ready/→shipped/ move) before starting pitch[i+1]; never overlap or parallelize.
3. **Dependency-order pre-check** — before building starts, read each pitch's `## Dependencies / Blocks-on:` edges; if argv order violates any declared edge, STOP and report the violation; do NOT auto-reorder.
4. **Mid-queue halt** — if pitch[i]'s cycle fails (gate fails after one dev retry), HALT at position i; do NOT skip ahead to pitch[i+1].

**Pre-check semantics**: The multi-pitch orchestrator reads `Blocks-on:` edges BEFORE any building starts. If a pitch declares `Blocks-on: foo` but `foo` is not in argv, or if argv order places a blocking pitch after the dependent pitch, the build stops immediately with a violation report. This prevents silent mis-ordering that would break build semantics.

**Example**: if argv is `claude-build b a` and pitch `b` contains `Blocks-on: a`, the orchestrator reports the violation and stops before invoking planner for either pitch.

**Prompt durability**: Self-references within prompt bodies should use section-name anchors (e.g., "the escape-hatch rule (step c')", "the U1–U7 option template") rather than absolute line numbers. Absolute line-number citations become stale whenever edits shift positions, introducing silent prompt drift. Section-name anchors remain valid across edits that shift line numbers, preventing re-rot.

**Pitch-format contract**: `shape.txt` and `ops.txt` both specify the EXACT grammar for `## Questions` / `## Answers` blocks in headless mode. The contract is machine-parseable and enforced at Stop time by the `pitch-format-validator.sh` Stop hook (fires for shape/ops roles). Grammar: each `### Q<n>:` heading must be followed by ≥2 `- **<letter>)**` option bullets; `## Answers` Q-bindings must reference matching Q headings in `## Questions`; `> Status:` (if present) must be SKELETON, SHAPING, or SHAPED. The `/document` slash command writes `> Status: SKELETON` as the first line of every new skeleton pitch. Shape sessions advance the status to SHAPING (mid-investigation) or SHAPED (fully designed).

**Slash commands**: Templates in `harnesses/claude/commands/*.md.j2` (Jinja2) are rendered by `generate.sh` → `templates/generated/claude-code/commands/` → installed to `~/.claude/commands/` by `install.sh`. Commands can spawn subagent swarms (e.g., `/poke-holes` spawns Explore agents). Gating via `operator-subagent-allowlist.sh` enforces role ∈ {debug, shape, ops}. Examples: `/ready` (readiness gate), `/poke-holes` (stress-test pitch via Explore swarm). Pi gets an inert copy of all commands; no Pi-specific overrides yet.

**Ready command source isolation**: `harnesses/claude/commands/ready.md.j2` includes ONLY `shared/prompt-fragments/_probing.txt` (inline Probe Discipline section), NOT `_authoring-spine.txt`. Any principle or content intended for the `/ready` command must be added directly to the `ready.md.j2` source file; edits to the spine fragment do not propagate to `/ready`. This isolation is intentional: the readiness gate is a focused, single-turn command distinct from the multi-turn shape investigative loop encoded in the spine.

**Empirical-claim probe-list homes** — allowed-probes enumeration authored in THREE places:

1. **`shared/prompt-fragments/_probing.txt`** — canonical source; included by `/ready` (ready.md.j2:46), `/poke-holes` (poke-holes.md.j2:33); appended to shape body via manifest
2. **`harnesses/shared/prompt-bodies/shape.txt`** — inline copy of allowed-probes + FORBIDDEN bullets (line 73); NOT an includer of the fragment
3. **`harnesses/claude/commands/ready.md.j2`** — inline copy of empirical-claim check (line 15); includes `_probing.txt` (line 46) for `/ready`

When modifying the probe-list, edits must land in all three homes. Treating shape.txt + ready.md.j2 as sufficient is the pitch-scoping error — `_probing.txt` ships in all four contexts (two harnesses' shape bodies, /ready, /poke-holes).

## Dispatcher Routing

`codegen-build` (see `context/core.md`) routes via `harnesses/<harness>/dispatch.sh`, which reads mode config and invokes the harness launcher:

```
claude-build.sh → codegen-build → harnesses/<harness>/dispatch.sh → execs claude-<mode>.sh / pi-<mode>.sh with model/effort/tools flags
```

For harness install contract details (agents_dir, hooks_dir, modes, launchers), see `harnesses/<harness>/manifest.yaml` documented in `context/core.md` Manifest Schema section.

## Config.yaml Runtime vs Baked Artifacts

**Key distinction**: `load-role.sh` reads `config.yaml` at _runtime_, NOT at install time. This differs from system prompts, which are baked at `make install`:

- **Build mode**: Uses baked prompt (`claude-build-system-prompt.txt`). `load-role.sh` is NOT invoked; tools/model/effort are already compiled into the prompt. Changes to config.yaml require `make install` to propagate.
- **Shape/ops/debug modes**: Use `load-role.sh` to read `config.yaml` at launcher time. Changes to config.yaml take effect _immediately on next invocation_ — no `make install` required.

**Tool allowlist enforcement**: The `--tools` flag passed to `claude`/`pi` CLI is populated by `load-role.sh` parsing `roles.<role>.tools[]` from config.yaml. Harness launcher `.sh` scripts gate tool spawning via the `--tools` flag, not system-prompt text. Thus, a new tool added to `config.yaml` → immediately available in shape/ops/debug sessions. Build mode does not use `load-role.sh`; build tools are static in the baked prompt body.

**`--agents` flag — size ceiling**: Passing the full custom-agent set to `claude` via the `--agents <json>` CLI flag does NOT work. A single argv string is capped at `MAX_ARG_STRLEN` (~128 KB on standard Linux, independent of the total `ARG_MAX` budget), and a complete `--agents` JSON blob overruns it — confirmed failed on a server. Therefore subagent _availability_ is gated by the `operator-subagent-allowlist.sh` PreToolUse hook, NOT by `--agents`. (Caching of agent files in the prompt prefix is a separate concern, covered in `context/claude-token-mechanics.md`; this note is about the launch-time argv limit.)

**Consequence**: Planner discovery of uncommitted config.yaml changes (in working tree, not yet staged) must be verified against the actual working tree file — not trusted from pitch state alone.

## Settings Overlay via `--settings` Flag

Claude Code supports a `--settings` JSON flag that provides a command-line scope overlay for user-level settings. This is the ONLY way to override user-scope settings like `MAX_THINKING_TOKENS` in a launcher.

**Settings precedence (highest to lowest)**: (1) Managed (admin), (2) Command-line `--settings '<json>'`, (3) Local `~/.claude/settings.json.local`, (4) Project `~/.claude/settings.json`, (5) User `~/.claude/settings.json`.

**Key fact**: Claude reads settings from the JSON FILE, not process environment. `env -u MAX_THINKING_TOKENS` is inert — environment deletion does not affect the setting. Only a `--settings` overlay beats the user-scope file.

**Use case — thinking tokens**: Shape/debug override via `--settings '{"env":{"MAX_THINKING_TOKENS":"16000"}}'` in `claude-shape.sh`/`claude-debug.sh`. Changes need `make install`. Build scripts needing custom budgets use `--settings`, not `env` or config.yaml overrides.

## Session Log Protocol

The orchestrator MUST pre-create the canonical session log (with full `## <agent_type> Section` headers) BEFORE delegating to any subagent (planner, developer, reviewer, etc.). This ensures:

1. All section headers exist when `subagent-retrospective-guard.sh` scans the log to confirm header presence before allowing Edit.
2. The planner writes the `## Plan` section into the orchestrator-created log, not a fresh one.
3. The retrospective-guard hook knows the correct `## Plan` block boundaries: the guard stops scanning for `### What I Learned This Step` blocks at the next `## ` H2 heading (which prevents it from false-matching retrospectives in subsequent agent sections).

The retrospective blocks MUST sit inside the `## Plan` body before any sibling H2 heading (e.g., `## Slices`). The guard parses the transcript to find the active session log path, then scans ONLY the `## Plan` section, stopping at the first H2 heading it encounters after the Plan start. Retrospectives appearing in agent sections (e.g., `## developer-phoenix-backend Section`) are not routed to the curator.

## Worktree Isolation (Native `--worktree`)

`claude --worktree <name>` / `-w` creates `.claude/worktrees/<name>/` on branch `worktree-<name>`. A `WorktreeCreate` hook fully replaces git logic (`.worktreeinclude` disabled). `worktree-create-phoenix.sh` seeds `deps` (symlink) + `_build` (copy, same-commit guard) + allocates a port via `resource_manager.sh`. `worktree-remove-phoenix.sh` releases the port (observe-only). Both events are in `PRESERVED_EVENTS` to survive `make install`.

The create hook is idempotent: a re-run re-attaches an already-registered worktree (skips `git worktree add`, re-allocates a fresh port, rewrites `.env` PORT lines) and attaches an orphaned branch without `-b`. So `claude-experiment <slug>` resumes an existing experiment; pass `--new` to force a fresh worktree (tears down the old worktree + branch first).

## Integration Points

- **core**: manifest.yaml `modes` section documents model/effort/tools per mode; config.yaml is canonical source; for manifest schema see `context/core.md`
- **subagents**: system prompt files include rendered agent rules baked at generate time
- **hooks**: `claude-code-settings.json` is source for hook registration; `hook_registrations.py` writes the installed version; see `context/hooks.md`
- **pi-extensions**: Pi launchers invoke compiled TypeScript extensions from `harnesses/pi/pi-extensions/`

## Direct-Build Mode (Pi-Specific)

Pi harness supports two operational modes via `dispatch.sh` SP_FILE selection:

- **Interactive mode** (`pi-build.sh` manual launcher): Full orchestrator workflow (5-role chain), consumes `pi-build-system-prompt.txt`
- **Non-interactive mode** (`codegen-build --harness=pi --non-interactive`): Direct-build single-process agent, consumes `pi-build-system-prompt-direct-phoenix.txt` or `pi-build-system-prompt-direct-static.txt` (stack-gated)

Mode selection gated by `$NON_INTERACTIVE` env var. Direct-build prompt forbids `mix phx.new` and orchestration vocabulary; app must be pre-scaffolded. Non-interactive mode removes subagents extension — skips the 5-role chain to fit small-model token budget. Test suite asserts compile + route + commit format only.

## Pi Extensions

Pi launchers load TypeScript extensions from `harnesses/pi/pi-extensions/` via compiled modules. Extensions are versioned with the harness and provide task-specific logic (dispatch, hook bindings, snippet handling). Extensions are invoked via flags, not indirectly by launcher env — see `harnesses/pi/<mode>.sh` for extension invocation signatures.

## Headless Investigative Mode

The three Claude investigative launchers (`claude-shape`, `claude-ops`, `claude-debug`) honor the `CLAUDE_NONINTERACTIVE` env var. When set to any non-empty value, each launcher builds a `NON_INTERACTIVE_FLAGS` array. **Important distinction**: investigative launchers deliberately restrict `--setting-sources` to `project` (no user-scope agents/hooks) because they export `CLAUDE_ROLE` and gate the Agent tool to project subagents only. Build dispatch (`codegen-build --non-interactive`) uses `user,project,local` to load the full agent set + user-level gating hooks.

Investigative launcher flags (`project` scope):

```
--print
--verbose
--output-format stream-json
--setting-sources project
--strict-mcp-config
--no-session-persistence
--disable-slash-commands
```

Build dispatch flags (`user,project,local` scope):

```
--print
--verbose
--output-format stream-json
--setting-sources user,project,local
--strict-mcp-config
--no-session-persistence
--disable-slash-commands
```

These flags are spliced as the **first positional** after `exec claude` (before `--model`). The env var name `CLAUDE_NONINTERACTIVE` intentionally diverges from `CODEGEN_BUILD_NON_INTERACTIVE` (dispatch) and `PI_NON_INTERACTIVE` (Pi).

**One-shot semantics**: headless investigative sessions run once and exit. There is no resume. If the agent needs a user decision (e.g., a pitch blocker in shape mode), it writes a `## Questions` block in the in-scope pitch file (permitted `codegen/pitches/` write) and stops. The operator answers out-of-band via a `## Answers` block; a fresh session continues.

### `/loop` Capability Matrix

| Mode                                                    | Scheduler tools granted                                         | `/loop` self-fires                                                                                        | Notes                                                                                                               |
| ------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Interactive ops/debug                                   | Yes (CronCreate, CronDelete, CronList, Monitor, ScheduleWakeup) | Yes — idle session persists between ticks                                                                 | Grant lives in `roles.ops.tools` / `roles.debug.tools` in `config.yaml`; read by `load-role.sh` as `--tools`        |
| Headless one-shot ops/debug (`CLAUDE_NONINTERACTIVE=1`) | Yes (tools in context)                                          | No — `--no-session-persistence` + `--print` exit on completion; no idle session for scheduler to re-enter | Prompt bodies detect recurring-poll requests and tell operator: use interactive session or set up external box-cron |
| shape                                                   | No (scheduler tools not in `roles.shape.tools`)                 | No                                                                                                        | shape is authoring-only; no polling use case                                                                        |

**SSH launchers (ops, debug)**: export `SSH_TARGET_NON_INTERACTIVE=1` when `CLAUDE_NONINTERACTIVE` is set; `ssh-target.sh` exits 1 on alias miss instead of prompting (no interactive hang in headless mode).

## See Also

See `context/launcher-hook-matrix.md` for which orchestrator-level hooks gate each launcher mode (build vs debug/shape/refactor vs ops).

## Prompt-Hygiene Pattern: Spawn Ritual

**Ordering problem**: Models treat multi-step instructions (Edit → Agent) as separable; regression cause is treating them as alternatives (pick one).

**Solution**: Name the pair "spawn ritual" and phrase as ONE atomic operation in the prompt. Same wording appears in both `harnesses/{claude,pi}/tools-header/build.txt` (lines 14–16) → models treat header-Edit + delegation as indivisible. Hard enforcement via `step-log-section-before-spawn.sh` (PreToolUse guard denies subagent spawn if header absent).

**Reusable pattern for similar regressions**: When a prompt should enforce a strictly-ordered multi-step sequence, give it a memorable name (ritual, ceremony, protocol) and describe it as ONE conceptual operation. The name prevents decomposition into pick-one choices.

## SSH Target Identity Persistence (`ssh-target.sh`)

**Two-identity model**: `ssh-target.sh` persists two user identities in `~/.ssh/config` alias blocks — (1) login user (`User <login>` line), (2) operate-as user (`# ops-operate-as: <user>` comment). Resolver exports `${PREFIX}_LOGIN_USER` and `${PREFIX}_OPERATE_AS` alongside `_SERVER`/`_ENV`.

**Backfill logic**: Alias with `HostName`-only triggers one-time interactive prompt → collects login user (default `root`) + operate-as (optional) → awk block-scoped rewrite via temp-file/mv. Guard: runs only when `User` line absent; idempotent on re-run.

**EOF-safe reads**: use `read -rp "..." var || true; var="${var:-default}"`. Under `SSH_TARGET_NON_INTERACTIVE=1`, all prompts skipped.

**Test-design constraint**: Pipe subshell exports invisible to parent — verify config file contents, not exported vars.

**Integration**: Ops/debug launchers source `ssh-target.sh`. Ops rule body (`prompt-bodies/ops.txt`) concatenated at generate-time into baked system-prompt; inert until `make install`.

## Launcher `.sh` Files: Runtime Scripts vs Baked Prompts

**Critical distinction**: Launcher `.sh` files (`harnesses/claude/claude-shape.sh`, `claude-debug.sh`, etc.) are **runtime scripts copied by `make install`**, not baked into system prompts. Edits to launcher flags propagate via the **install process**, not via prompt-content-parity sentinel sync.

**Key implications**:

- Editing `claude-shape.sh` line 49 (`--settings '{"env":{"MAX_THINKING_TOKENS":"16000"}}'`) → `make install` copies the updated script to `~/.claude/claude-shape` → next invocation uses new budget. No sentinel-sync needed.
- Launcher edits are runtime-effective; they do NOT participate in system-prompt baking or prompt-content-parity verification.
- To verify a launcher flag change took effect: check `~/.claude/claude-<mode>` directly, or run the launcher with `--verbose` to see the exec'd command line.

**Contrast**: System prompt bodies (`harnesses/shared/prompt-bodies/shape.txt`) ARE baked and DO require sentinel sync in `prompt-content-parity_test.sh`.

## Pitfalls

- **Never hand-edit `*-system-prompt.txt`** — generated by `manifest_regenerate_prompts()`; edits are overwritten on next `make install`
- **Mode tools lists** are canonical in `config.yaml` (not in manifest `modes` — manifest is documentation-of-record only)
- **`dispatch.sh` uses `COMMON_FLAGS` array** — under `set -u`, use `"${ARR[@]+"${ARR[@]}"}"` for empty-safe splicing
- **SP_FILE is required** — `claude-build-system-prompt.txt` must exist before exec; dispatch.sh exits 2 if absent (mirrors TOOLS_FILE guard). Pi selects stack-gated direct-build prompts (-phoenix/-static) via `$STACK`.
- **Build dispatch is hermetic + fail-loud** — dispatch.sh guards yq/config-parse with named exit-2 errors, and unsets `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` before exec (provider-key parity with pi). Paired test: `harnesses/claude/hooks/dispatch_test.sh`.
- **prompt_body is a YAML sequence** — manifest's `prompt_body` is an ordered list, not a scalar; `manifest_regenerate_prompts()` iterates it; missing entries → non-zero exit (no partial prompt written)
- **Fragment paths** are relative to `CODEGEN_DIR` — `shared/prompt-fragments/_probing.txt` NOT `harnesses/shared/...`; process_template.py resolves `{% include %}` under `$CODEGEN_DIR/shared/`
- **ready.md.j2 is a template** — `harnesses/claude/commands/ready.md.j2` is rendered by `generate.sh` to `templates/generated/claude-code/commands/ready.md`; `install.sh` installs from generated dir; never install from source `.j2` directly
- **Spawn ritual wording** — identical in both harnesses (claude/pi `tools-header/build.txt` L14–16) because downstream agents inherit from both harnesses; edits to one must verify parity in the other. Second-to-land edits confirm by text match.
