# Harnesses Domain — Claude + Pi Harness Specifics

The harnesses domain covers the per-harness launcher scripts, dispatch logic, mode definitions, system prompt assembly, and settings files. Each harness (Claude Code, Pi) has its own directory under `harnesses/` with a manifest, launcher scripts, system prompt `.txt` files, `tools-header/` fragments, and a `dispatch.sh` that selects mode and invokes the underlying CLI.

System prompt assembly: `tools-header/<mode>.txt` + entries in `prompt_body[]` (manifest order) → `<harness>-<mode>-system-prompt.txt` via `manifest_regenerate_prompts()`. Empty files in prompt_body are skipped.

## Components

| File / Dir                                                | Purpose                                            |
| --------------------------------------------------------- | -------------------------------------------------- |
| `harnesses/claude/claude-{debug,experiment,shape,ops}.sh` | Mode launchers                                     |
| `harnesses/claude/dispatch.sh`                            | Mode dispatcher                                    |
| `harnesses/claude/load-role.sh`                           | Runtime config reader (shape/ops/debug/experiment) |
| `harnesses/claude/tools-header/`                          | Per-mode prompt headers                            |
| `harnesses/claude/claude-code-settings.json`              | Hook/permission config (source)                    |
| `harnesses/pi/pi-{debug,experiment,shape,ops}.sh`         | Pi mode launchers                                  |
| `harnesses/pi/dispatch.sh`                                | Pi mode dispatcher                                 |
| `harnesses/shared/prompt-bodies/`                         | Shared prompt body (both harnesses)                |
| `shared/prompt-fragments/`                                | Reusable fragments                                 |
| `harnesses/claude/commands/`                              | Slash commands (`.md.j2` templates)                |

## Dispatch & Session Re-Attach API

**Claude re-attach flag**: `claude --resume <id>` (full or partial UUID). Valueless `--resume` opens interactive session picker. Dispatch MUST emit `--resume "$id"` only when id is non-empty; never emit valueless flag.

**Pi re-attach flag**: `pi --session <path|id>` (full or partial UUID or file path). Pi has `--session-id <id>` which CREATES a new session if the id doesn't exist — wrong for re-attach (would silently start fresh on stale id). Always use `--session "$id"` for re-attach semantics (fails on stale id, correct error path). Dispatch MUST emit `--session "$id"` only when id is non-empty.

**One-shot launcher boundary**: `claude-ops.sh`, `claude-shape.sh`, `claude-debug.sh`, `call-dispatch.sh` are single-invocation launchers with UNCONDITIONAL `--no-session-persistence` (Claude) or `--no-session` (Pi). `codegen-build`/`dispatch.sh` (the build path) has no resumable/resume-id flags at all — it always execs the deterministic Elixir orchestration loop.

**`call-dispatch.sh` optional transcript capture**: both harness `call-dispatch.sh` scripts honor an optional `CODEGEN_CALL_TRANSCRIPT_PATH` env var — when set, the captured stream-json is copied there on the EXIT trap before the temp file is deleted (fail-loud-non-blocking: a copy failure prints to stderr but never changes the exit code); unset = current behavior (no copy). Consumed by the Elixir orchestration loop for durable per-role transcripts; see `context/test-harness.md` § Orchestration Loop.

**Pi agent `.md` files carry YAML frontmatter** — `templates/generator/generate.sh`'s `_generate_pi` renders `name`/`description`/`model`/`tools` via `process_template.py --config config.yaml <tpl> pi true`. The `tools:` line is authored in claude vocabulary in the shared `.md.j2` source and translated to pi vocabulary (`bash, edit, find, grep, ls, read, write` + extension tools `subagent, ask_user_question, web_search, fetch_webpage`) through `config.yaml`'s `tools.pi.tool_map` — de-duped, order-preserved (`Edit`+`MultiEdit` both collapse to `edit`). An unmapped claude tool ABORTS generation loud (pi silently ignores unknown `--tools` names at runtime — probed — so generation time is the only guard against a silently-narrowed allowlist). `harnesses/pi/call-dispatch.sh`'s `_resolve_pi_agent` strips that frontmatter before passing the body as `--system-prompt` (leaking raw YAML into the prompt would corrupt every pi role's identity) and emits the parsed `tools:` value as `pi --tools <list>`; an explicit `--allowed-tools`/`CODEGEN_CALL_ALLOWED_TOOLS_SET` still wins over the agent's frontmatter, mirroring claude's precedence. A frontmatter-less legacy agent file (first line not `---`) still works — the whole file is the identity body, no `--tools` emitted. Slash-command templates (`description:`-only frontmatter, no `tools:` line) render unchanged — this is the only no-op path.

## Consumer Role Definition

A role = one `codegen-call` invocation. Identity flags: `--system-prompt` (REPLACE = whole identity), `--model`, `--effort`, `--harness`, `--allowed-tools`, `--settings @<path>` (claude enforcement bundle) / `--extension @<path>` (pi). No role name is hardcoded; a consumer defines an arbitrary role with these flags and ZERO codegen change. One-way boundary: `codegen-call` never references a consumer role name.

## Key Paths

```
harnesses/claude/
  claude-build.sh, claude-debug.sh, claude-experiment.sh, claude-shape.sh, claude-ops.sh
  dispatch.sh, load-role.sh
  tools-header/{debug,experiment,shape,ops}.txt  ← disk path uses hyphen
  claude-code-settings.json
  commands/
harnesses/pi/
  pi-build.sh, pi-debug.sh, pi-experiment.sh, pi-shape.sh, pi-ops.sh
  dispatch.sh
  pi-prompts/
harnesses/shared/prompt-bodies/
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

| Mode  | tools-header contains (per-harness)                                                                                                        | prompt_body list (shared)                                                                                                                                      |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| debug | `## Tools` + harness-specific tool list + FORBIDDEN list + cross-repo grep allowance                                                       | [harnesses/shared/prompt-bodies/debug.txt] — no-cat-pipe line + Protocol + Forbidden + Refusal & Pivot                                                         |
| shape | `## Tools` + harness-specific tool bullets (claude: Agent/Skill/AskUserQuestion/Write-Edit; pi: askuserquestion/subagents/web-utils names) | [harnesses/shared/prompt-bodies/shape.txt, shared/prompt-fragments/_probing.txt, shared/prompt-fragments/_authoring-spine.txt] — mode-title + no-cat-pipe line |
| ops   | `## Tools` + harness-specific per-tool bullets                                                                                             | [harnesses/shared/prompt-bodies/ops.txt] — starts with Cold-Start Opening block, followed by procedural ops rules                                              |

**Placement checklist**:

- **→ per-harness header**: Tool names differing (claude `Agent` vs pi `subagents`); launcher flags; install paths; protocol names
- **→ shared body**: Neutral tool discipline; orchestration rules; commit hygiene; harness-agnostic behavior

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Prompt-body assembly mechanism**: `manifest_regenerate_prompts()` in `manifest-lib.sh` concatenates all `prompt_body[]` entries verbatim via `cat`, producing the baked `*-system-prompt.txt` files. No Jinja processing, no deduplication. Order affects the byte sequence in the baked prompt (entries are concatenated in list order).

**Per-harness vs shared bodies**: All modes use `harnesses/shared/prompt-bodies/`. Per-harness body dirs no longer exist. Shape appends shared fragments (`_probing.txt`, `_authoring-spine.txt`). SSH context for debug/ops injected via `--append-system-prompt`, not baked. Shared body files in both manifests → one edit bakes both harnesses at `make install`.

**Sentinel propagation**: Sentinels in `prompt_body[]` or appended fragments reach the baked prompt. Shape feeds two sources; sentinels in either propagate. Duplicates in baked prompt are harmless for presence tests.

**Shape investigative disciplines**: Shape mode includes `_authoring-spine.txt`, which encodes readiness-loop gates (context load → investigation → readiness check). Spine enforces six core rules (A–F): intent-guard, plain-language, command-pairing auto-cover, dedup, symptom-vs-target, context-drift auto-cover. Also enforces deletion-safety blockers: un-investigated rabbit holes, untraced edit surface, dangling cross-refs. See `context/subagents.md` § Authoring Spine Rules. Intent-guard (A) patched into empirical-claim option-(b) in `shape.txt`, forbidding any readiness option to nullify core intent.

**Shaper ask-vs-decide classifier**: Ask when answer changes product behavior (UX, copy, intent fork). Never-ask: tools, models, env, naming, placement. Behaviors: (1) answered-question memory (no re-ask), (2) cold-start raw-material (reads input, writes SKELETON drafts). Auto-decide engineering choices; record as `Assumed: key=value`.

**SSH target resolution paths (ops/debug launchers)**: `resolve_ssh_target()` in `ssh-target.sh` has three distinct resolution outcomes: (1) **HIT** — candidate alias is found in `~/.ssh/config` as a defined Host; (2) **MISS-save** — user typed a bare IP that `ssh -G` cannot resolve; treat the IP as a new Host and save it to config under the candidate alias name; (3) **MISS-existing** — user typed an alias that IS defined in `~/.ssh/config` but differs from the candidate (user deliberately chose an existing alias, not the candidate). The connect alias MUST be different on the third path: use `$user_alias` (what the user typed, which IS a real Host), NOT `$candidate` (which has no defined Host block on this path). All three paths export `${prefix}_ALIAS` for consumption by launchers (debug/ops). When `${prefix}_ALIAS` is empty, fall back to `server_resolved` (bare IP) so the exported value is never empty and launcher self-check commands (`ssh ${DEBUG_ALIAS}`) remain well-formed. Tests assert the alias export on all three paths: `T-new-11` (HIT), `T-new-12` (MISS-save), `T-new-13` (MISS-existing).

**Per-harness header rewrite discipline (shape mode)**: Shape headers were historically identical clones, leaking Claude vocab into Pi. Rewrites must replace all Claude-specific terms (tool names: `Agent`/`Skill`/`AskUserQuestion`/`Write`/`Edit`; paths like `~/.claude/hooks/`, `~/.claude/settings.json`; refs like `orchestrator-no-source-edit.sh`) with Pi equivalents. Neutral lines (mode-title, tool-usage) relocate to shared `harnesses/shared/prompt-bodies/shape.txt`. Omit lines with no Pi equivalent (e.g., `Skill`). After rewrite: headers differ, neutral content appears once.

**Shared body relocation pitfall** — avoid NEW section headings when relocating lines. Even sensible headings cause false-positive diffs caught by post-relocation assertions. Keep structural headings in headers; move only prose. Example: `## FIRST-TURN PROTOCOL` stays in headers; prose bullets move to body. Heading structure remains per-harness.

**Fragment references in shared bodies** — `_authoring-spine.txt` references `~/.claude/settings.json` as a debugging target for enforcement-bug investigation. This is SHARED investigative discipline (correct in Pi assembled prompt). Distinction: `~/.claude/hooks/` / `orchestrator-no-source-edit.sh` are Claude-only (remove from Pi header); `~/.claude/settings.json` as inspection target is cross-harness (keep in shared).

**Deferral-with-draft contract**: Every deferral MUST be backed by real `codegen/pitches/draft/<slug>.md`. Prose-only deferral = blocker. Security/safety deferrals must state exposure assumptions.

**Decompose-then-split rule** (Rule G): SPLIT multi-surface problems into independent pitches (eng-decomposition, not user choice). Only product forks reach user.

**Derive-and-write dependency edges rule** (Rule H): DERIVE dependency edges from code and WRITE them into the pitch's `blocks_on:` YAML frontmatter flow-list (dual-read fallback: legacy `Blocks-on:` prose); omitted edges → silent mis-order. Auto-derive; ask only on circular/ambiguous cases.

## Multi-Pitch Protocol

Multi-pitch handling (`--queue`) is now owned entirely by the Elixir loop's `mix codegen.loop.queue` (`CodegenTestHarness.LoopQueueDrain.drain/1`) — see `context/test-harness.md` § Orchestration Loop for the topo-sort, `blocks_on:` pre-check, and per-pitch sequencing contract. There is no per-harness tools-header prose for this anymore.

**Pitch-format contract**: `shape.txt` and `ops.txt` specify EXACT grammar for `## Questions` / `## Answers` in headless mode. Machine-parseable; enforced by `pitch-format-validator.sh` Stop hook (shape/ops). Grammar: `### Q<n>:` + ≥2 `- **<letter>)**` options; `## Answers` references matching Q headings; `status:` (YAML frontmatter, dual-read fallback: legacy `> Status:` blockquote) ∈ {SKELETON, SHAPING, SHAPED}. `/document` writes `status: SKELETON` in frontmatter. Shape advances to SHAPING/SHAPED and persists a `summary:` field at SHAPED.

**Slash commands**: Templates in `harnesses/claude/commands/*.md.j2` rendered by `generate.sh` → `templates/generated/claude-code/commands/` → installed to `~/.claude/commands/`. Can spawn swarms (e.g., `/poke-holes`). Gated by `operator-subagent-allowlist.sh` to {debug, shape, ops}. Examples: `/ready`, `/poke-holes`. Pi gets inert copy.

**Ready command source isolation**: `ready.md.j2` includes ONLY `_probing.txt`, NOT `_authoring-spine.txt`. Spine-fragment edits don't propagate to `/ready`. Intentional: `/ready` is single-turn; spine encodes multi-turn shape loop.

**Empirical-claim probe-list homes**: (1) canonical `_probing.txt`, (2) inline shape.txt, (3) ready.md.j2. Edits land in all three or pitch-scoping fails.

## Dispatcher Routing

`codegen-build` (see `context/core.md`) routes via `harnesses/<harness>/dispatch.sh`, which reads mode config and invokes the harness launcher:

```
claude-build.sh → codegen-build → harnesses/<harness>/dispatch.sh → execs claude-<mode>.sh / pi-<mode>.sh with model/effort/tools flags
```

For harness install contract details (agents_dir, hooks_dir, modes, launchers), see `harnesses/<harness>/manifest.yaml` documented in `context/core.md` Manifest Schema section.

## Config.yaml Runtime vs Baked Artifacts

**Key distinction**: `load-role.sh` reads `config.yaml` at _runtime_, NOT at install time. This differs from system prompts, which are baked at `make install`:

- **Shape/ops/debug modes**: Use `load-role.sh` to read `config.yaml` at launcher time. Changes to config.yaml take effect _immediately on next invocation_ — no `make install` required.
- **Build**: has no launcher-side mode config at all — `dispatch.sh` always execs the Elixir loop, which resolves model/effort per-role itself.

**Tool allowlist enforcement**: The `--tools` flag passed to `claude`/`pi` CLI is populated by `load-role.sh` parsing `roles.<role>.tools[]` from config.yaml. Harness launcher `.sh` scripts gate tool spawning via the `--tools` flag, not system-prompt text. Thus, a new tool added to `config.yaml` → immediately available in shape/ops/debug sessions. Build has no launcher-side mode; the loop resolves per-role tool allowlists itself.

**`--agents` flag — size ceiling**: Passing the full custom-agent set to `claude` via the `--agents <json>` CLI flag does NOT work. A single argv string is capped at `MAX_ARG_STRLEN` (~128 KB on standard Linux, independent of the total `ARG_MAX` budget), and a complete `--agents` JSON blob overruns it — confirmed failed on a server. Therefore subagent _availability_ is gated by the `operator-subagent-allowlist.sh` PreToolUse hook, NOT by `--agents`. (Caching of agent files in the prompt prefix is a separate concern, covered in `context/claude-token-mechanics.md`; this note is about the launch-time argv limit.)

**Consequence**: Planner discovery of uncommitted config.yaml changes (in working tree, not yet staged) must be verified against the actual working tree file — not trusted from pitch state alone.

## Settings Overlay via `--settings` Flag

Claude Code supports a `--settings` JSON flag that provides a command-line scope overlay for user-level settings. This is the ONLY way to override user-scope settings like `MAX_THINKING_TOKENS` in a launcher.

**Settings precedence (highest to lowest)**: (1) Managed (admin), (2) Command-line `--settings '<json>'`, (3) Local `~/.claude/settings.json.local`, (4) Project `~/.claude/settings.json`, (5) User `~/.claude/settings.json`.

**Key fact**: Claude reads settings from the JSON FILE, not process environment. `env -u MAX_THINKING_TOKENS` is inert — environment deletion does not affect the setting. Only a `--settings` overlay beats the user-scope file.

**Use case — thinking tokens**: Shape/debug override via `--settings '{"env":{"MAX_THINKING_TOKENS":"16000"}}'` in `claude-shape.sh`/`claude-debug.sh`. Changes need `make install`. Build scripts needing custom budgets use `--settings`, not `env` or config.yaml overrides.

**Use case — AFK timeout**: Interactive-only launchers (shape/debug/experiment/ops) gate `CLAUDE_AFK_TIMEOUT_MS=86400000` on `[[ -z "${CLAUDE_NONINTERACTIVE:-}" ]]` to keep AskUserQuestion dialogs open 24h instead of auto-continuing at 60s. Each launcher computes `SETTINGS_JSON` or `SETTINGS_FLAGS` after the NON_INTERACTIVE_FLAGS block: interactive branch adds the AFK key; headless branch omits it or uses the unchanged object. `--settings` merges key-by-key with `~/.claude/settings.json` (probe #3 in async validation). Headless/build paths keep the 60s Claude Code default — setting must NOT appear in global `~/.claude/settings.json` (no-go constraint: unattended AskUserQuestion would hang 24h).

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

`pi-build.sh` / `codegen-build --harness=pi` always route the build to `harnesses/pi/dispatch.sh`, which unconditionally execs `mix codegen.loop --harness=pi`. There is no `build` manifest mode, no baked build system prompt, and no build-time extension loading in dispatch.sh anymore — the loop resolves each role's model/effort/tools itself via `codegen-call`. `codegen-build` still fails closed unless the gate result JSON written to `codegen/gate-pending/` carries a `clear` verdict.

`dispatch.sh` (both harnesses) unconditionally execs `mix codegen.loop` — the deterministic Elixir orchestration loop is the sole build engine; there is no engine flag, no TTY auto-detection, and no legacy self-orchestrating fallback. The parent wrapper (`codegen-build`) decides build success from the structured gate result written to `codegen/gate-pending/gate-result.json`.

## EXEC-MECHANICS vs SYSTEM-PROMPT-CONTENT: Orthogonal Concerns in Harness Design (Historical)

The build path's cutover from a self-orchestrating harness session to the deterministic Elixir orchestration loop is COMPLETE — `dispatch.sh` unconditionally execs `mix codegen.loop`, there is no legacy engine, no resumable/non-interactive build flags, and no build-mode system prompt. This section previously documented the transitional coexistence period; retained only as a note that when refactoring ANY orchestration mechanism in the future, separate EXEC-MECHANICS (how agents run: session persistence, re-attach, launch order) from SYSTEM-PROMPT-CONTENT (what the prompt tells the agent to do) as two distinct layers before deleting either.

## Pi Extensions

Pi launchers load TypeScript extensions from `harnesses/pi/pi-extensions/` via compiled modules. Extensions are versioned with the harness and provide task-specific logic (dispatch, hook bindings, snippet handling). Extensions are invoked via flags, not indirectly by launcher env — see `harnesses/pi/<mode>.sh` for extension invocation signatures.

## Headless Investigative Mode

The three Claude investigative launchers (`claude-shape`, `claude-ops`, `claude-debug`) honor the `CLAUDE_NONINTERACTIVE` env var. When set to any non-empty value, each launcher builds a `NON_INTERACTIVE_FLAGS` array. **Important distinction**: investigative launchers deliberately restrict `--setting-sources` to `project` (no user-scope agents/hooks) because they export `CLAUDE_ROLE` and gate the Agent tool to project subagents only. Build dispatch (`codegen-build --non-interactive`) uses `user,project,local` to load the full agent set + user-level gating hooks.

**`CLAUDE_NONINTERACTIVE` branch signal**: The same condition `[[ -n "${CLAUDE_NONINTERACTIVE:-}" ]]` that gates `NON_INTERACTIVE_FLAGS` array building also gates interactive-vs-headless `--settings` JSON/array construction in shape/debug/experiment/ops launchers. When the condition is true (headless), `SETTINGS_JSON` or `SETTINGS_FLAGS` use the unchanged object (no AFK-timeout key); when false (interactive, env empty or unset), the object adds `CLAUDE_AFK_TIMEOUT_MS`. This co-location ensures the two branches stay synchronized and prevents accidental 24h hangs on headless builds.

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

These flags are spliced as the **first positional** after `exec claude` (before `--model`). The env var name `CLAUDE_NONINTERACTIVE` intentionally diverges from `PI_NON_INTERACTIVE` (Pi) — these are investigative-mode (debug/ops) toggles, unrelated to the build path (which has no non-interactive flag at all).

**One-shot semantics**: headless investigative sessions run once and exit. There is no resume. If the agent needs a user decision (e.g., a pitch blocker in shape mode), it writes a `## Questions` block in the in-scope pitch file (permitted `codegen/pitches/` write) and stops. The operator answers out-of-band via a `## Answers` block; a fresh session continues.

### `/loop` Capability Matrix

| Mode                                                    | Scheduler tools granted                                         | `/loop` self-fires                                                                                        | Notes                                                                                                               |
| ------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Interactive ops/debug                                   | Yes (CronCreate, CronDelete, CronList, Monitor, ScheduleWakeup) | Yes — idle session persists between ticks                                                                 | Grant lives in `roles.ops.tools` / `roles.debug.tools` in `config.yaml`; read by `load-role.sh` as `--tools`        |
| Headless one-shot ops/debug (`CLAUDE_NONINTERACTIVE=1`) | Yes (tools in context)                                          | No — `--no-session-persistence` + `--print` exit on completion; no idle session for scheduler to re-enter | Prompt bodies detect recurring-poll requests and tell operator: use interactive session or set up external box-cron |
| shape                                                   | No (scheduler tools not in `roles.shape.tools`)                 | No                                                                                                        | shape is authoring-only; no polling use case                                                                        |

**SSH launchers (ops, debug)**: export `SSH_TARGET_NON_INTERACTIVE=1` when `CLAUDE_NONINTERACTIVE` is set; `ssh-target.sh` exits 1 on alias miss instead of prompting (no interactive hang in headless mode).

## Operator vs Batch Divergence Intentional

Different exec modes (interactive vs CI, operator vs batch) → different output format, persistence, hardening flags. Don't unify these. Unify shared config only: model, tools, base prompt. ❌ Force single launcher path ✅ Two launchers, one config block.

## See Also

See `context/launcher-hook-matrix.md` for which orchestrator-level hooks gate each launcher mode (build vs debug/shape/refactor vs ops).

## Prompt-Hygiene Pattern: Spawn Ritual

**Ordering problem**: Models treat multi-step instructions (Edit → Agent) as separable; regression cause is treating them as alternatives (pick one).

**Solution**: Name the pair "spawn ritual" and phrase as ONE atomic operation in the prompt when a mode still needs manual header-Edit + Agent() sequencing (e.g., shape/ops/debug). The build path no longer needs this pattern at all — the Elixir orchestration loop invokes each role directly and writes each role's session-log section itself.

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

- **Never hand-edit `*-system-prompt.txt`** — generated by `manifest_regenerate_prompts()`; overwritten on `make install`
- **Mode tools lists canonical in `config.yaml`** — manifest is documentation only
- **Build dispatch is hermetic** — `dispatch.sh` (both harnesses) always execs `mix codegen.loop`; unsets API keys before exec; test: `dispatch_test.sh`
- **`prompt_body` is ordered list** — missing entries → non-zero exit
- **Fragment paths relative to `CODEGEN_DIR`** — process_template.py resolves under `$CODEGEN_DIR/shared/`
- **Installed launchers have full `harnesses/` tree** — check `~/.local/bin/harnesses/` to verify dispatch.sh edits propagated
- **`codegen-log section` + developer role** — sets `CLAUDE_ROLE` explicitly to avoid 3-strike gate collision; use Edit tool as workaround
- **`ready.md.j2` is template** — generated by `generate.sh`; never install from source `.j2` directly
- **`harnesses/shared/` scripts are NOT installed alongside launchers** — `install.sh` symlinks launchers to `~/.local/bin/` but NOT `harnesses/shared/`. Launchers calling `$SCRIPT_DIR/../shared/` work in repo but fail post-install. Fix: use `$OCG_CODEGEN_DIR/harnesses/shared/<script>.sh` with fallback, or add to manifest install steps.
- **Launcher tree-climbing** — Check `OCG_CODEGEN_DIR`, then fallback.

## Runtime Porting — Reduced Fidelity Across Harnesses

When porting a guard/hook from Claude (Bash) to Pi (TypeScript), the runtime capabilities may differ:

- **Transcript access**: Claude has JSONL transcript inspection via `jq` + `TRANSCRIPT_PATH`; Pi has no transcript. Guards depending on transcript-based detection cannot be ported with full fidelity. Write a reduced-fidelity observe-only twin with disk-scan heuristics + explicit header comment documenting the gap.
- **Event blocking asymmetry**: Claude's Stop event can block; Pi's `session_shutdown` is observe-only. All 4 Stop/SubagentStop twins emit stderr warnings, NEVER `block()`.

The goal is truthful hooks that accurately reflect capability limits, not feature parity claims that hide missing capabilities.

## Trigger Keywords

claude-build, claude-debug, claude-shape, pi-build, dispatch.sh, launcher, system prompt, modes, tools-header, new launcher mode, claude-ops, pi-ops, CLAUDE_ROLE, per-mode hook bypass, claude-experiment.sh, harness-parity launcher tests, operator vs batch divergence, runtime porting, reduced fidelity, transcript access, event blocking asymmetry
