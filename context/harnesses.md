# Harnesses Domain — Claude + Pi Harness Specifics

The harnesses domain covers the per-harness launcher scripts, dispatch logic, mode definitions, system prompt assembly, and settings files. Each harness (Claude Code, Pi) has its own directory under `harnesses/` with a manifest, launcher scripts, system prompt `.txt` files, `tools-header/` fragments, and a `dispatch.sh` that selects mode and invokes the underlying CLI.

System prompt assembly: `tools-header/<mode>.txt` + entries in `prompt_body[]` (manifest order) → `<harness>-<mode>-system-prompt.txt` via `manifest_regenerate_prompts()`. Empty files in prompt_body are skipped.

## Components

| File / Dir                                        | Purpose                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------ |
| `harnesses/claude/claude-build.sh`                | Build mode launcher — sets model/effort, invokes `claude`                      |
| `harnesses/claude/claude-debug.sh`                | Debug mode launcher (Opus, high effort)                                        |
| `harnesses/claude/claude-experiment.sh`           | Experiment mode (Opus, high, source-writable, `--worktree exp-<slug>`)         |
| `harnesses/claude/claude-shape.sh`                | Shape mode (Opus, high effort, web tools)                                      |
| `harnesses/claude/claude-ops.sh`                  | Ops mode launcher (Opus, high effort)                                          |
| `harnesses/claude/dispatch.sh`                    | Mode dispatcher — reads manifest, sets flags, execs claude                     |
| `harnesses/claude/load-role.sh`                   | Runtime config reader for shape/ops/debug/experiment; skipped in build (baked) |
| `harnesses/claude/tools-header/`                  | Per-mode prompt headers (build, debug, experiment, shape, ops)                 |
| `harnesses/claude/claude-code-settings.json`      | Claude Code hook/permission config (source)                                    |
| `harnesses/claude/claude-build-system-prompt.txt` | Generated — concat of tools-header + prompt-body (do not hand-edit)            |
| `harnesses/claude/commands/`                      | Slash commands → `~/.claude/commands/`                                         |
| `harnesses/pi/pi-build.sh`                        | Pi build mode launcher                                                         |
| `harnesses/pi/pi-debug.sh`                        | Pi debug mode launcher                                                         |
| `harnesses/pi/pi-experiment.sh`                   | Experiment mode (tool-allowlist + prompt confinement)                          |
| `harnesses/pi/pi-shape.sh`                        | Pi shape mode launcher                                                         |
| `harnesses/pi/pi-ops.sh`                          | Pi ops mode launcher                                                           |
| `harnesses/pi/dispatch.sh`                        | Pi mode dispatcher                                                             |
| `harnesses/pi/pi-prompts/`                        | Pi-specific prompt fragments                                                   |
| `harnesses/shared/prompt-bodies/`                 | Shared body text (build, debug, experiment, shape, ops) — both harnesses       |
| `shared/prompt-fragments/`                        | Reusable fragments (`_probing.txt`, `_authoring-spine.txt`)                    |
| `harnesses/claude/commands/`                      | Slash commands (`.md.j2` templates) → `~/.claude/commands/`                    |

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
  shape-draft.txt ← Capture-append mode prompt (NOT baked via manifest; read directly by launchers for --draft flag)
  ops.txt        ← Rule 1-5 procedural ops rules (shared between claude/pi)
shared/prompt-fragments/
  _probing.txt         ← Inline Probe Discipline section (included in shape + /ready)
  _authoring-spine.txt ← Phase 0 (9-step), Multi-turn, Adjacent, Output Contract, Rules, Anti-patterns
```

## Mode Launcher Cloning Pattern

Clone existing launcher: swap role name, log prefixes, mode-specific flags (e.g., `--worktree`). Two config blocks REQUIRED when Claude/Pi read different paths: `roles.<mode>` (load-role.sh) + `harness.<mode>.pi` (yq). NOT redundant — both committed. Update both manifests' `modes.<mode>` + launcher/completion registration + tools_header/prompt_body refs. All `.txt` files must pre-exist; `manifest_regenerate_prompts()` exits non-zero if missing.

## Completions Installation Path

Zsh completions (e.g., `_claude-experiment`) install from `harnesses/<harness>/_<name>` via manifest-driven loop in `install.sh` (the `install_completions` block); fully manifest-controlled, no separate dir. Naming: underscore prefix required (`_claude-experiment`); `#compdef` names the context.

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

**Placement checklist** — content location decision:

- **→ per-harness header** (must differ):
  - Tool names differing per harness (e.g., claude `Agent` vs pi `subagents`)
  - Launcher flags / hook-capability differences
  - Install paths specific to one harness (`~/.claude/hooks/`, `~/.claude/settings.json`)
  - Per-harness protocol names (`## Cycle Protocol` vs `## Step Queue Protocol`)
  - Harness-specific ritual wording, invocation sentence, post-commit hook names

- **→ shared body** (identical across harnesses):
  - Neutral tool-usage discipline (no-cat-pipe, no-explore)
  - Orchestration rules (session logs, context-curator naming)
  - Commit Hygiene, WHY-handoff, cold-start gates
  - Harness-agnostic behavior (headless mode, output style, forbidden actions)

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Per-harness vs shared bodies**: All modes use `harnesses/shared/prompt-bodies/`. Per-harness body dirs no longer exist. Shape appends shared fragments (`_probing.txt`, `_authoring-spine.txt`). SSH context for debug/ops injected via `--append-system-prompt`, not baked. Shared body files in both manifests → one edit bakes both harnesses at `make install`.

**Sentinel propagation**: Sentinels in `prompt_body[]` or appended fragments reach the baked prompt. Shape feeds two sources; sentinels in either propagate. Duplicates in baked prompt are harmless for presence tests.

**Shape investigative disciplines**: Shape mode includes `_authoring-spine.txt`, which encodes readiness-loop gates (context load → investigation → readiness check). Spine enforces six core rules (A–F): intent-guard, plain-language, command-pairing auto-cover, dedup, symptom-vs-target, context-drift auto-cover. Also enforces deletion-safety blockers: un-investigated rabbit holes, untraced edit surface, dangling cross-refs. See `context/subagents.md` § Authoring Spine Rules. Intent-guard (A) patched into empirical-claim option-(b) in `shape.txt`, forbidding any readiness option to nullify core intent.

**Shaper ask-vs-decide classifier** (hardened): Ask ONLY when answer changes user experience or user-controlled identity — UX copy/flow/behavior, product-intent fork (A vs B), user-owned identity. Test: "Does answer change PRODUCT behavior?" If no → auto-decide. Never-ask: tools/models, environment, input processing, pitch scope, naming, dir/file placement. Behaviors: (1) **answered-question memory** — scan prior answers; already-answered/deflected = binding (no re-ask); (2) **cold-start raw-material** — user arrives with audio/notes → shaper states plan, reads material, writes SKELETON pitches into `codegen/pitches/draft/`. Auto-decide engineering choices: install-guarantee, fail-closed-when-guaranteed, internal naming, split strategy (record as `Assumed: <key> = <value>`; override rule at step c' in shape.txt).

**SSH target resolution paths (ops/debug launchers)**: `resolve_ssh_target()` in `ssh-target.sh` has three distinct resolution outcomes: (1) **HIT** — candidate alias is found in `~/.ssh/config` as a defined Host; (2) **MISS-save** — user typed a bare IP that `ssh -G` cannot resolve; treat the IP as a new Host and save it to config under the candidate alias name; (3) **MISS-existing** — user typed an alias that IS defined in `~/.ssh/config` but differs from the candidate (user deliberately chose an existing alias, not the candidate). The connect alias MUST be different on the third path: use `$user_alias` (what the user typed, which IS a real Host), NOT `$candidate` (which has no defined Host block on this path). All three paths export `${prefix}_ALIAS` for consumption by launchers (debug/ops). When `${prefix}_ALIAS` is empty, fall back to `server_resolved` (bare IP) so the exported value is never empty and launcher self-check commands (`ssh ${DEBUG_ALIAS}`) remain well-formed. Tests assert the alias export on all three paths: `T-new-11` (HIT), `T-new-12` (MISS-save), `T-new-13` (MISS-existing).

**Per-harness header rewrite discipline (shape mode)**: Shape headers were historically identical clones, leaking Claude vocab into Pi. Rewrites must replace all Claude-specific terms (tool names: `Agent`/`Skill`/`AskUserQuestion`/`Write`/`Edit`; paths like `~/.claude/hooks/`, `~/.claude/settings.json`; refs like `orchestrator-no-source-edit.sh`) with Pi equivalents. Neutral lines (mode-title, tool-usage) relocate to shared `harnesses/shared/prompt-bodies/shape.txt`. Omit lines with no Pi equivalent (e.g., `Skill`). After rewrite: headers differ, neutral content appears once.

**Shared body relocation pitfall** — avoid NEW section headings when relocating lines. Even sensible headings cause false-positive diffs caught by post-relocation assertions. Keep structural headings in headers; move only prose. Example: `## FIRST-TURN PROTOCOL` stays in headers; prose bullets move to body. Heading structure remains per-harness.

**Fragment references in shared bodies** — `_authoring-spine.txt` references `~/.claude/settings.json` as a debugging target for enforcement-bug investigation. This is SHARED investigative discipline (correct in Pi assembled prompt). Distinction: `~/.claude/hooks/` / `orchestrator-no-source-edit.sh` are Claude-only (remove from Pi header); `~/.claude/settings.json` as inspection target is cross-harness (keep in shared).

**Deferral-with-draft contract**: Every deferral (deferred/future work/phase 2/out-of-scope/cut-1) MUST be backed by a real `codegen/pitches/draft/<slug>.md`. Pitch references it (e.g., "deferred — see `<slug>`"). Prose-only deferral = blocker, not resolution. Security/safety deferrals (auth, access, secrets, deletion) must state exposure assumption in draft rationale (e.g., "safe only while box unreachable"). Prevents shipped incomplete features.

**Decompose-then-split rule** (Rule G): Shaper SPLITS problems spanning multiple surfaces/missing prerequisites into N independently-buildable pitches — NOT asking user "split how?". Splitting is eng-decomposition, not user choice. Only product forks (feature A vs B) reach user. Emit: `Decomposed: extracted pitches <slug-1>, <slug-2> …`

**Derive-and-write dependency edges rule** (Rule H): Shaper DERIVES build-order edges (code reading) and WRITES as `Blocks-on: <slug>` in `## Dependencies` blocks. Omitted edges → silent mis-order. Shaper does NOT ask user. Circular/ambiguous from code → AskUserQuestion. Derivable → auto-decide. Grammar in `pitch-format-contract.md`. Every split MUST have correct `## Dependencies` blocks.

## Multi-Pitch Protocol

Per-harness tools-headers now contain complete multi-pitch sequencing rules for handling multiple pitches in a single build invocation (`claude-build a b c` or `pi-build a b c`).

**Why per-harness**: Claude and Pi have different concurrency models (Claude cycles through planner/dev/gate/reviewer/curator/committer; Pi processes sequential step queues). The four-rule protocol is identical in INTENT but expressed in per-harness vocabularies to align with each harness's native concepts:

- **Claude** (`harnesses/claude/tools-header/build.txt` — the Cycle Protocol section) — uses "cycle" and "pitch" vocabulary; sequences via `Cycle Protocol` section
- **Pi** (`harnesses/pi/tools-header/build.txt` — the Step Queue Protocol section) — uses "step queue" and "queue position" vocabulary; sequences via the multi-pitch sequencing rules in Step Queue Protocol

**The five rules** (identical intent, harness-specific vocabulary):

1. **One session log per pitch** — each pitch file gets its own `<ts>_<slug>_session.md` log; never combine pitches.
2. **Strict sequencing** — complete the full cycle/queue for pitch[i] (including ready/→shipped/ move) before starting pitch[i+1]; never overlap or parallelize.
3. **Dependency-order pre-check** — before building starts, read each pitch's `## Dependencies / Blocks-on:` edges; if argv order violates any declared edge, STOP and report the violation; do NOT auto-reorder.
4. **Mid-queue halt** — if pitch[i]'s cycle fails (gate fails after one dev retry), HALT at position i; do NOT skip ahead to pitch[i+1].
5. **Queue continuity is autonomous** — after pitch[i] ships, immediately begin pitch[i+1]'s cycle with zero interruption: emit no chat text, ask zero questions. NEVER solicit user permission to continue ("Should I proceed with pitch #2?", "Should I continue?", "are you stopping these builds intentionally?"). The ONLY legitimate stop is rule 4 (Mid-queue halt on gate failure).

**Pre-check semantics**: The multi-pitch orchestrator reads `Blocks-on:` edges BEFORE any building starts. If a pitch declares `Blocks-on: foo` but `foo` is not in argv, or if argv order places a blocking pitch after the dependent pitch, the build stops immediately with a violation report. This prevents silent mis-ordering that would break build semantics.

**Example**: if argv is `claude-build b a` and pitch `b` contains `Blocks-on: a`, the orchestrator reports the violation and stops before invoking planner for either pitch.

**Prompt durability**: Use section-name anchors in self-references (e.g., "step c'", "U1–U7 template"), not absolute line numbers. Line-number citations go stale → silent drift. Section-name anchors survive line-number shifts.

**Pitch-format contract**: `shape.txt` and `ops.txt` specify EXACT grammar for `## Questions` / `## Answers` in headless mode. Machine-parseable; enforced by `pitch-format-validator.sh` Stop hook (shape/ops). Grammar: `### Q<n>:` + ≥2 `- **<letter>)**` options; `## Answers` references matching Q headings; `> Status:` ∈ {SKELETON, SHAPING, SHAPED}. `/document` writes `> Status: SKELETON`. Shape advances to SHAPING/SHAPED.

**Slash commands**: Templates in `harnesses/claude/commands/*.md.j2` rendered by `generate.sh` → `templates/generated/claude-code/commands/` → installed to `~/.claude/commands/`. Can spawn swarms (e.g., `/poke-holes`). Gated by `operator-subagent-allowlist.sh` to {debug, shape, ops}. Examples: `/ready`, `/poke-holes`. Pi gets inert copy.

**Ready command source isolation**: `ready.md.j2` includes ONLY `_probing.txt`, NOT `_authoring-spine.txt`. Spine-fragment edits don't propagate to `/ready`. Intentional: `/ready` is single-turn; spine encodes multi-turn shape loop.

**Empirical-claim probe-list homes** — allowed-probes authored in THREE places:

1. `shared/prompt-fragments/_probing.txt` — canonical; included by `/ready` + `/poke-holes`; appended to shape body
2. `harnesses/shared/prompt-bodies/shape.txt` — inline copy (allowed-probes + FORBIDDEN)
3. `harnesses/claude/commands/ready.md.j2` — inline copy; includes `_probing.txt` for `/ready`

Edits must land in all three. Skipping `_probing.txt` causes pitch-scoping error — it ships in four contexts.

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

## Orchestrated Build Mode (Pi-Specific)

Pi build now uses the same orchestrated contract in both launcher paths:

- `pi-build.sh` / `codegen-build --harness=pi` consume `pi-build-system-prompt.txt`
- `harnesses/pi/dispatch.sh` loads the build extensions declared in `harnesses/pi/manifest.yaml` (`askuserquestion`, `subagents`, `enforcement`)
- caller-supplied `--extension` flags remain additive
- the legacy `pi-build-system-prompt-direct-*.txt` files remain tracked, but build dispatch no longer consumes them
- `codegen-build` fails closed unless Pi returns a clear `codegen/gate-pending/gate-result.json`

Mode selection still honors the build launcher’s non-interactive env, but the prompt body is no longer direct-build-only. The build path is orchestrated; the parent wrapper decides success from the structured gate result.

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

**Solution**: Name the pair "spawn ritual" and phrase as ONE atomic operation in the prompt. Same wording appears in both `harnesses/{claude,pi}/tools-header/build.txt` (the `"spawn ritual = header-Edit + Agent() call, always as indivisible pair"` line in FIRST-TURN PROTOCOL) → models treat header-Edit + delegation as indivisible. Hard enforcement via `step-log-section-before-spawn.sh` (PreToolUse guard denies subagent spawn if header absent).

**Reusable pattern for similar regressions**: When a prompt should enforce a strictly-ordered multi-step sequence, give it a memorable name (ritual, ceremony, protocol) and describe it as ONE conceptual operation. The name prevents decomposition into pick-one choices.

## SSH Target Identity Persistence (`ssh-target.sh`)

**Two-identity model**: `ssh-target.sh` persists two user identities in `~/.ssh/config` alias blocks — (1) login user (`User <login>` line), (2) operate-as user (`# ops-operate-as: <user>` comment). Resolver exports `${PREFIX}_LOGIN_USER` and `${PREFIX}_OPERATE_AS` alongside `_SERVER`/`_ENV`.

**Backfill logic**: Alias with `HostName`-only triggers one-time interactive prompt → collects login user (default `root`) + operate-as (optional) → awk block-scoped rewrite via temp-file/mv. Guard: runs only when `User` line absent; idempotent on re-run.

**EOF-safe reads**: use `read -rp "..." var || true; var="${var:-default}"`. Under `SSH_TARGET_NON_INTERACTIVE=1`, all prompts skipped.

**Test-design constraint**: Pipe subshell exports invisible to parent — verify config file contents, not exported vars.

**Integration**: Ops/debug launchers source `ssh-target.sh`. Ops rule body (`prompt-bodies/ops.txt`) concatenated at generate-time into baked system-prompt; inert until `make install`.

## Platform Repo Makefile Targets

The platform (codegen) repo uses `make test` as the gate command, NOT `make ci` (no ci target). Downstream app repos (Phoenix/static) may differ — always verify the Makefile target exists before specifying gate commands in a `## Plan` gate-json block. The `gate_select_read_planner_json` hook reads gate commands ONLY from the `## Plan` section (awk exits on next `## ` header); gate-json in developer/reviewer sections is invisible to the gate hook.

## Gate-JSON Section Visibility

The gate-selection hook (`harnesses/claude/hooks/lib/gate-select.sh`) reads ```gate-json blocks from the `## Plan`section ONLY. A gate-json block appearing in any other section (e.g.,`## developer-phoenix-backend Section`) is not parsed and the gate command is never triggered. Always place gate-json inside `## Plan` above any sibling H2 headings (`## Slices`, etc.). If gate-json is moved or edited in a non-Plan section during development, the gate hook will fail to find it and fall back to prose-based `**Gate**:`fallback (less reliable). Verify gate-json is in`## Plan` before closing the planning phase.

## Launcher `.sh` Files: Runtime Scripts vs Baked Prompts

**Critical distinction**: Launcher `.sh` files (`harnesses/claude/claude-shape.sh`, `claude-debug.sh`, etc.) are **runtime scripts copied by `make install`**, not baked into system prompts. Edits to launcher flags propagate via the **install process**, not via prompt-content-parity sentinel sync.

**Key implications**:

- Editing the `--settings` flag in `claude-shape.sh` (the `MAX_THINKING_TOKENS` line) → `make install` copies the updated script to `~/.claude/claude-shape` → next invocation uses new budget. No sentinel-sync needed.
- Launcher edits are runtime-effective; they do NOT participate in system-prompt baking or prompt-content-parity verification.
- To verify a launcher flag change took effect: check `~/.claude/claude-<mode>` directly, or run the launcher with `--verbose` to see the exec'd command line.

**Contrast**: System prompt bodies (`harnesses/shared/prompt-bodies/shape.txt`) ARE baked and DO require sentinel sync in `prompt-content-parity_test.sh`.

## Shape Launcher `--draft` Flag

Both shape launchers (`claude-shape.sh`, `pi-shape.sh`) accept a `--draft <path> "text"` flag that activates **capture-append mode**:

- Swaps the system prompt to `shape-draft.txt` (read directly via `cat`; NOT baked via manifest pipeline).
- Injects the target path and text to append into the prompt.
- Skips Tier-0/Tier-1 context loads, the pitch basename resolver, and the shaping/readiness loop.
- The LLM agent performs the append (Edit/Write on `<path>`); the launcher does NOT append directly.
- `orchestrator-no-source-edit.sh` write-scope guard (already scopes shape role to `codegen/pitches/`) is inherited — no new guard needed.

**Validation**: path missing on disk → stderr + exit 1; text absent → stderr usage + exit 2.
**`shape-draft.txt`** is NOT registered in any `manifest.yaml` `modes.shape.prompt_body[]` — only read at runtime by the launcher via `cat` (direct file read). No manifest/generator wiring; no sentinel sync required in `prompt-content-parity_test.sh` for this launcher-direct-read file (the test targets baked system-prompt content, not runtime launcher reads).

## Pitfalls

- **Never hand-edit `*-system-prompt.txt`** — generated by `manifest_regenerate_prompts()`; edits are overwritten on next `make install`
- **Mode tools lists** are canonical in `config.yaml` (not in manifest `modes` — manifest is documentation-of-record only)
- **`dispatch.sh` uses `COMMON_FLAGS` array** — under `set -u`, use `"${ARR[@]+"${ARR[@]}"}"` for empty-safe splicing
- **SP_FILE is required** — `claude-build-system-prompt.txt` must exist before exec; dispatch.sh exits 2 if absent (mirrors TOOLS_FILE guard). Pi selects stack-gated direct-build prompts (-phoenix/-static) via `$STACK`.
- **Build dispatch is hermetic + fail-loud** — dispatch.sh guards yq/config-parse with named exit-2 errors, and unsets `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` before exec (provider-key parity with pi). Paired test: `harnesses/claude/hooks/dispatch_test.sh`.
- **prompt_body is a YAML sequence** — manifest's `prompt_body` is an ordered list, not a scalar; `manifest_regenerate_prompts()` iterates it; missing entries → non-zero exit (no partial prompt written)
- **Fragment paths** are relative to `CODEGEN_DIR` — `shared/prompt-fragments/_probing.txt` NOT `harnesses/shared/...`; process_template.py resolves `{% include %}` under `$CODEGEN_DIR/shared/`
- **Installed launcher directory structure** — `codegen-build`'s installed copy at `~/.local/bin/codegen-build` derives `SCRIPT_DIR` from its own location (`~/.local/bin`), so its `DISPATCH="$SCRIPT_DIR/harnesses/$HARNESS/dispatch.sh"` resolves to `~/.local/bin/harnesses/claude/dispatch.sh` (or pi equivalent). A full copy of the `harnesses/` tree is installed alongside the launcher, not just the wrapper script itself. When verifying a dispatch.sh edit propagated post-install, grep or inspect `~/.local/bin/harnesses/claude/dispatch.sh`, not just the launcher wrapper resolved via `command -v codegen-build` (which is the wrapper path, not the dispatch script path).
- **`codegen-log section` role-gate interaction** — `codegen-log section --body @-` requires `CLAUDE_ROLE` or `AGENT_TYPE` set for header derivation. Explicitly exporting `CLAUDE_ROLE=<role>` on the Bash call causes developer-role hooks to classify the invocation as a developer-role command and count it against the `developer-no-self-gate` 3-strike CI-adjacent cap (e.g., 2 strikes already used by `make install` + `make test`), blocking the log write when at capacity. Workaround: write the session log section body directly via the Edit tool instead when role-gating prevents `codegen-log section` invocation. This applies to developer-specific sections being written from within the developer role's work phase; other roles (planner, reviewer, curator, committer) do not hit the 3-strike cap.
- **ready.md.j2 is a template** — `harnesses/claude/commands/ready.md.j2` is rendered by `generate.sh` to templates/generated/claude-code/commands/ready.md (generated, not committed); `install.sh` installs from generated dir; never install from source `.j2` directly
- **Spawn ritual wording** — identical in both harnesses (claude/pi `tools-header/build.txt` FIRST-TURN PROTOCOL spawn-ritual line) because downstream agents inherit from both harnesses; edits to one must verify parity in the other. Second-to-land edits confirm by text match.
