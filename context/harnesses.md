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

**One-shot launcher boundary**: `claude-ops.sh`, `claude-shape.sh`, `claude-debug.sh`, `call-dispatch.sh` are single-invocation (Claude sessions persist by default now, no opt-out flag; Pi keeps `--no-session`). `codegen-build`/`dispatch.sh` has no resume flags — always execs the Elixir loop.

**`call-dispatch.sh` optional transcript capture**: both harness `call-dispatch.sh` scripts honor an optional `CODEGEN_CALL_TRANSCRIPT_PATH` env var — when set, the captured stream-json is copied there on the EXIT trap before the temp file is deleted (fail-loud-non-blocking: a copy failure prints to stderr but never changes the exit code); unset = current behavior (no copy). Consumed by the Elixir orchestration loop for durable per-role transcripts; see `context/test-harness.md` § Orchestration Loop.

**Pi bounded call transport**: Pi output passes through tracked `pi-jsonl-filter.cjs` before capture; only `message_update` snapshots omitted. Dispatcher runs from immutable temp snapshot, owns Pi via process-group supervisor, records Pi PID for tool-child detection, treats Pi+filter as one lifecycle. Terminal `agent_end` salvageable; every filter/setup fatal path reaps Pi before failing. Repeated `--extension` values retain order → repeated Pi `--extension` argv.

**Pi agent `.md` files carry YAML frontmatter** — `generate.sh`'s `_generate_pi` renders `name`/`description`/`model`/`tools` via `process_template.py --config config.yaml <tpl> pi true`. `tools:` authored in claude vocab in shared `.md.j2` source, translated to pi vocab (`bash, edit, find, grep, ls, read, write` + extension tools `subagent, ask_user_question, web_search, fetch_webpage`) via `config.yaml`'s `tools.pi.tool_map` — de-duped, order-preserved (`Edit`+`MultiEdit` collapse to `edit`). Unmapped claude tool ABORTS generation loud (pi ignores unknown `--tools` at runtime, so gen-time is the only guard). `call-dispatch.sh`'s `_resolve_pi_agent` strips frontmatter before passing body as `--system-prompt`, emits parsed `tools:` as `pi --tools <list>`; explicit `--allowed-tools`/`CODEGEN_CALL_ALLOWED_TOOLS_SET` still wins. Frontmatter-less legacy file (first line not `---`) still works — whole file is identity body, no `--tools` emitted. Slash-command templates (`description:`-only) render unchanged — the only no-op path.

## Consumer Role Definition

A role = one `codegen-call` invocation. Identity flags: `--system-prompt` (REPLACE = whole identity), `--model`, `--effort`, `--harness`, `--allowed-tools`, `--settings @<path>` (claude enforcement bundle) / `--extension @<path>` (pi, repeatable and ordered). No role name is hardcoded; a consumer defines an arbitrary role with these flags and ZERO codegen change. One-way boundary: `codegen-call` never references a consumer role name.

## Key Paths

```
harnesses/claude/
  claude-build.sh, claude-debug.sh, claude-experiment.sh, claude-shape.sh, claude-ops.sh, claude-babysit.sh
  dispatch.sh, load-role.sh
  tools-header/{debug,experiment,shape,ops,babysit}.txt  ← disk path uses hyphen
  claude-code-settings.json
  commands/
harnesses/pi/
  pi-build.sh, pi-debug.sh, pi-experiment.sh, pi-shape.sh, pi-ops.sh, pi-babysit.sh
  dispatch.sh
  prompt-bodies/shape.txt (Pi-native; pi-prompts/ dir removed — dead dup of generated /document)
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

| Mode  | tools-header contains (per-harness)                                                                                                                   | prompt_body list (shared)                                                                                                                                                                                                                         |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| debug | `## Tools` + harness-specific tool list + FORBIDDEN list + cross-repo grep allowance                                                                  | [harnesses/shared/prompt-bodies/debug.txt] — no-cat-pipe line + Protocol + Forbidden + Refusal & Pivot                                                                                                                                            |
| shape | `## Tools` + harness-specific tool bullets (claude: Agent/Skill/AskUserQuestion/Write-Edit; pi: askuserquestion/subagents/web-utils/pitch_move names) | claude: [harnesses/shared/prompt-bodies/shape.txt, _probing.txt, _authoring-spine.txt]; pi: [**harnesses/pi/prompt-bodies/shape.txt** (Pi-native, NOT shared — duplicates blocker-scan prose, parity-tested), _probing.txt, _authoring-spine.txt] |
| ops   | `## Tools` + harness-specific per-tool bullets                                                                                                        | [harnesses/shared/prompt-bodies/ops.txt] — starts with Cold-Start Opening block, followed by procedural ops rules                                                                                                                                 |

**Placement checklist**:

- **→ per-harness header**: Tool names differing (claude `Agent` vs pi `subagents`); launcher flags; install paths; protocol names
- **→ shared body**: Neutral tool discipline; orchestration rules; commit hygiene; harness-agnostic behavior

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Prompt-body assembly mechanism**: `manifest_regenerate_prompts()` in `manifest-lib.sh` concatenates all `prompt_body[]` entries verbatim via `cat`, producing the baked `*-system-prompt.txt` files. No Jinja processing, no deduplication. Order affects the byte sequence in the baked prompt (entries are concatenated in list order).

**Per-harness vs shared bodies**: All modes use `harnesses/shared/prompt-bodies/`. Per-harness body dirs no longer exist. Shape appends shared fragments (`_probing.txt`, `_authoring-spine.txt`). SSH context for debug/ops injected via `--append-system-prompt`, not baked. Shared body files in both manifests → one edit bakes both harnesses at `make install`.

**Sentinel propagation**: Sentinels in `prompt_body[]` or appended fragments reach the baked prompt. Shape feeds two sources; sentinels in either propagate. Duplicates in baked prompt are harmless for presence tests.

**Shape investigative disciplines**: Shape mode includes `_authoring-spine.txt`, encoding readiness-loop gates (context load → investigation → readiness check). Spine enforces ten core rules (A–J); A–H (intent-guard, plain-language, command-pairing auto-cover, dedup, symptom-vs-target, context-drift auto-cover, decompose-then-split, derive-and-write edges) live in `_authoring-spine.txt`; I/J (ask-vs-decide, deferral-with-draft) live in `shaper-discipline.md`. Also enforces deletion-safety blockers: rabbit holes, untraced edit surface, dangling refs. See `context/subagents.md` § Authoring Spine Rules. Intent-guard (A) patched into empirical-claim option-(b) in `shape.txt`.

**Shaper ask-vs-decide classifier (I)**: Ask only when answer changes product behavior. Never-ask: tools, models, env, naming, placement. Auto-decide engineering choices; record `Assumed: key=value`. Sibling of `shaper-discipline.md` § Ask-vs-Decide Classifier.

**SSH target resolution paths (ops/debug launchers)**: `resolve_ssh_target()` in `ssh-target.sh` has three outcomes: (1) **HIT** — candidate alias found in `~/.ssh/config`; (2) **MISS-save** — bare unresolvable IP typed; saved as new Host under candidate alias; (3) **MISS-existing** — user typed an alias defined in config but differing from candidate (deliberate choice). Third path MUST connect via `$user_alias` (real Host), NOT `$candidate` (no Host block there). All paths export `${prefix}_ALIAS`; empty falls back to `server_resolved` (bare IP) so launcher self-checks (`ssh ${DEBUG_ALIAS}`) stay well-formed. Tests: `T-new-11` (HIT), `T-new-12` (MISS-save), `T-new-13` (MISS-existing).

**Per-harness header rewrite discipline (shape mode)**: Shape headers were historically identical clones, leaking Claude vocab into Pi. Rewrites must replace all Claude-specific terms (tool names: `Agent`/`Skill`/`AskUserQuestion`/`Write`/`Edit`; paths like `~/.claude/hooks/`, `~/.claude/settings.json`; refs like `orchestrator-no-source-edit.sh`) with Pi equivalents. Neutral lines (mode-title, tool-usage) relocate to shared `harnesses/shared/prompt-bodies/shape.txt`. Omit lines with no Pi equivalent (e.g., `Skill`). After rewrite: headers differ, neutral content appears once.

**Shared body relocation pitfall** — avoid NEW section headings when relocating lines. Even sensible headings cause false-positive diffs caught by post-relocation assertions. Keep structural headings in headers; move only prose. Example: `## FIRST-TURN PROTOCOL` stays in headers; prose bullets move to body. Heading structure remains per-harness.

**Fragment references in shared bodies** — `_authoring-spine.txt` references `~/.claude/settings.json` as a debugging target for enforcement-bug investigation. This is SHARED investigative discipline (correct in Pi assembled prompt). Distinction: `~/.claude/hooks/` / `orchestrator-no-source-edit.sh` are Claude-only (remove from Pi header); `~/.claude/settings.json` as inspection target is cross-harness (keep in shared).

**Deferral-with-draft contract**: Every deferral MUST be backed by real `codegen/pitches/draft/<slug>.md`. Prose-only deferral = blocker. Security/safety deferrals must state exposure assumptions. A CONCRETE, path-bearing deferral additionally gets a bilateral `handoffs:` record in both pitches (never prose alone) — see `context/pitch-lifecycle.md` § Frontmatter Schema.

**Decompose-then-split rule** (Rule G): SPLIT multi-surface problems into independent pitches (eng-decomposition, not user choice). Only product forks reach user. Before writing, rule G runs the one-clause test (rule H outcome (e)) itself: one-purpose pieces collapse into one pitch, never split; a surviving split records `split_subject: A; B` per sibling — `mix codegen.pitches.scope --check` fails an unproven SUBSUMED pair.

**Derive-and-write dependency edges rule** (Rule H): DERIVE dependency edges from code and WRITE them into the pitch's `blocks_on:` YAML frontmatter flow-list (dual-read fallback: legacy `Blocks-on:` prose); omitted edges → silent mis-order. Auto-derive; ask only on circular/ambiguous cases.

## Multi-Pitch Protocol

Multi-pitch handling (`--queue`) is owned entirely by the Elixir loop's `mix codegen.loop.queue` (`CodegenTestHarness.LoopQueueDrain.drain/1`) — see `context/test-harness.md` § Orchestration Loop for the topo-sort, `blocks_on:` pre-check, and per-pitch sequencing contract. The babysit mode's tools-header (both Claude and Pi) + shared prompt-body name the drain dispatch command (`codegen-build --queue --watch`); no OTHER per-harness tools-header carries queue prose.

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

**Use case — thinking tokens**: All 5 Claude modes (debug/shape/experiment/ops/babysit) declare `roles.<mode>.thinking_tokens` (16000) in `config.yaml`; `load-role.sh` fail-loud validates + exports `ROLE_THINKING_TOKENS`. Launchers build `--settings` with `MAX_THINKING_TOKENS` interpolated from that var — never a literal — on BOTH interactive/headless branches, overriding installed global `=0` (one-shot/build calls keep 0). Guard: `harnesses/shared/mode-thinking-parity_test.sh`. `make install` propagates config changes.

**Use case — AFK timeout**: Interactive-only launchers (debug/shape/experiment/ops/babysit) gate `CLAUDE_AFK_TIMEOUT_MS=86400000` on `[[ -z "${CLAUDE_NONINTERACTIVE:-}" ]]` vs auto-continuing at 60s. Interactive adds the AFK key to `SETTINGS_JSON`; headless omits it. `--settings` merges key-by-key with `~/.claude/settings.json`. Headless/build keep the 60s default — must NOT appear in global settings.

**Use case — idle-session monitor**: same branch also forks `harnesses/shared/shape-idle-monitor.sh` pre-`exec` (`$$` survives `exec` → REPL PID). Binds to its transcript via set-diff vs a pre-exec snapshot; ambiguous (0/≥2 new `*.jsonl`) → fail-silent forever. Polls ~30s: dead PID → self-exit; frozen past `CODEGEN_SHAPE_IDLE_WARN_SECS` (default 600s) + last entry ≠ `assistant` → one bell+banner on REPL tty, re-arms on progress. Warn-only; `CODEGEN_SHAPE_IDLE_KILL=1` opts into SIGTERM. Fail-open/silent on any error. Headless: none of this.

## Session Log Protocol

The loop creates the cycle log via `codegen-log init --slug <slug> --stamp <ts>` BEFORE delegating to any subagent — passing its own already-minted `stamp` (naming the run's `cycle_id`/transcript dir), so the log stem equals `cycle_id` and a retry of the same slug mints its own log. Append-only JSONL, not markdown — no header-boundary scan. Each role writes via `codegen-log section <role> --slug <slug>` (stdin body), appending `{"ev":"role","role":<role>,"body":<prose>}`. Full contract: `shared/rules/_core/session-log.md`.

Retrospective capture: `role-retrospective-before-stop.sh` (Claude: blocking `Stop`; Pi: observe-only `session_shutdown` twin) asserts the stopping role's log carries a non-empty `ev:role` body plus `ev:learned`/`ev:no_learning` — via reader selectors, not markdown scanning. `context-curator`/`committer` not gated. Full CLI contract: `shared/rules/_core/session-log.md` § Ownership/Enforcement.

## Worktree Isolation (Native `--worktree`)

`claude --worktree <name>` / `-w` creates `.claude/worktrees/<name>/` on branch `worktree-<name>`. A `WorktreeCreate` hook fully replaces git logic (`.worktreeinclude` disabled). `worktree-create-phoenix.sh` seeds `deps` (symlink) + `_build` (copy, same-commit guard) + allocates a port via `resource_manager.sh`. `worktree-remove-phoenix.sh` releases the port (observe-only). Both events are in `PRESERVED_EVENTS` to survive `make install`.

The create hook is idempotent: a re-run re-attaches an already-registered worktree (skips `git worktree add`, re-allocates a fresh port, rewrites `.env` PORT lines) and attaches an orphaned branch without `-b`. So `claude-experiment <slug>` resumes an existing experiment; pass `--new` to force a fresh worktree (tears down the old worktree + branch first).

## Integration Points

- **core**: manifest.yaml `modes` section documents model/effort/tools per mode; config.yaml is canonical source; for manifest schema see `context/core.md`
- **subagents**: system prompt files include rendered agent rules baked at generate time
- **hooks**: `claude-code-settings.json` is source for hook registration; `hook_registrations.py` writes the installed version; see `context/hooks.md`
- **pi-extensions**: Pi launchers invoke compiled TypeScript extensions from `harnesses/pi/pi-extensions/`

## Orchestrated Build Mode (Pi-Specific)

`pi-build.sh` / `codegen-build --harness=pi` always route the build to `harnesses/pi/dispatch.sh`, which unconditionally execs `mix codegen.loop --harness=pi`. No `build` manifest mode, no baked build system prompt, no build-time extension loading — the loop resolves each role's model/effort/tools itself via `codegen-call`.

`dispatch.sh` (both harnesses) unconditionally invokes `mix codegen.loop` — the sole build engine; no engine flag, no TTY auto-detection, no legacy fallback. A successful `codegen-build` run requires BOTH a fresh, loop-owned `build-result.json` (matching the mktemp'd `CODEGEN_BUILD_INVOCATION_ID` the wrapper exported, slug captured from the prompt path before dispatch can ship `ready/<slug>.md`, current HEAD, `status: success`) AND `gate-result.json.verdict == "clear"` — see `context/loop.md` § Interrupted-Cycle Recovery. Checkpoint evidence (`gate-result.json`, `cycle-state.json`) is never eagerly deleted pre-dispatch; only a stale `build-result.json` is cleared.

**Loop-child exit record**: `dispatch.sh` job-controls the spawn (`set -m`, non-exec, to trap+forward SIGTERM to the child's process group — see `build_signal_handler.ex`), tees child stderr to a bounded (~8 KB) temp file through a named FIFO (never `/dev/fd` process substitution), keeps loop stdout byte-transparent, preserves the loop's own status explicitly, and after `wait`ing (`wait "$child_pid" || exit_code=$?`, never bare — `set -e` would abort on a bare non-zero `wait`) writes ONE `{"ev":"exit","status":<n>,"signal":<n-or-null>,"stderr_tail":<text>}` event via `codegen-log exit`, pinned to whichever log `.active` names if it changed during the spawn; otherwise one stderr note, nothing written. Fail-loud-non-blocking: a `codegen-log exit` failure never changes the propagated `exit_code`.

## EXEC-MECHANICS vs SYSTEM-PROMPT-CONTENT (Historical)

Cutover complete. Future refactors: separate EXEC-MECHANICS (session persistence, re-attach, launch order) from SYSTEM-PROMPT-CONTENT before deleting either.

## Mode → Declared Context

babysit/ops/debug/shape/experiment each declare loaded context in ONE place: `config.yaml` `roles.<mode>.context_files` (repo-relative paths). babysit: PROJECT_CONTEXT.md, deployment-topology.md, loop-queue-drain.md, pitch-lifecycle.md. ops: PROJECT_CONTEXT.md, deployment-topology.md, port-allocation.md. debug: PROJECT_CONTEXT.md, deployment-topology.md, launcher-hook-matrix.md. shape/experiment: `[]` — named exemption, resolves dynamically via `harnesses/shared/pitch-context-selector.sh` (Tier-0 Always-Load + citation-prioritized Tier-1, cap 6; explicit `context/<name>.md` citation outranks incidental keyword match).

`mode-context.sh` (`resolve_mode_context <mode>`) is sole reader; resolves paths against `$CODEGEN_DIR` (not cwd), exports `ROLE_CONTEXT_FILES`. `load-role.sh` calls it in `load_role()`; the 3 pi launchers (no `load_role`) call it directly. Missing declared path → hard `exit 1` naming mode+path.

Claude loops `ROLE_CONTEXT_FILES` into `--append-system-prompt` flags + startup string; Pi (no such flag) concatenates onto `ROLE_SYSTEM_PROMPT` before its startup concat.

Guard: `mode-context-parity_test.sh` (auto-discovered via `harness-parity`'s `harnesses/shared/*_test.sh` glob).

## Pi Extensions

Pi launchers load TypeScript extensions from `harnesses/pi/pi-extensions/` via compiled modules. Extensions are versioned with the harness and provide task-specific logic (dispatch, hook bindings, snippet handling). Extensions are invoked via flags, not indirectly by launcher env — see `harnesses/pi/<mode>.sh` for extension invocation signatures.

## Pi Provider Selection

No pi launcher site passes `--provider` — inferred from `<provider>/` model prefix. Full contract: `context/role-config.md` § Pi Provider Selection.

## Headless Investigative Mode

The Claude investigative/supervisory launchers (`claude-shape`, `claude-ops`, `claude-debug`, `claude-babysit`) honor the `CLAUDE_NONINTERACTIVE` env var. When set to any non-empty value, each launcher builds a `NON_INTERACTIVE_FLAGS` array. **Important distinction**: investigative launchers deliberately restrict `--setting-sources` to `project` (no user-scope agents/hooks) because they export `CLAUDE_ROLE` and gate the Agent tool to project subagents only. Build dispatch (`codegen-build --non-interactive`) uses `user,project,local` to load the full agent set + user-level gating hooks.

**`CLAUDE_NONINTERACTIVE` branch signal**: same condition `[[ -n "${CLAUDE_NONINTERACTIVE:-}" ]]` also gates interactive-vs-headless `--settings` construction in shape/debug/experiment/ops launchers — headless omits `CLAUDE_AFK_TIMEOUT_MS`, interactive adds it — and, in `claude-shape.sh` only, whether the idle-session monitor forks at all. Co-located to stay synced and prevent accidental 24h hangs / stray monitors on headless builds.

Shared flags: `--print --verbose --output-format stream-json --strict-mcp-config --no-session-persistence --disable-slash-commands`. Only `--setting-sources` differs: investigative launchers use `project`; build dispatch uses `user,project,local`.

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

### Break-glass jumpstart boundary

Future `{claude,pi}-jumpstart` (Codex later): operator-supervised incident mode, outside normal loop + role guards, repairs stale lifecycle state. Keeps data-preservation + destructive-action safety. Not implemented by this canary. Entry requires explicit operator incident judgment — never auto-selected by queue/drain automation.

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

**Bash 3.2 empty-array splat constraint**: macOS system bash (3.2.57) treats `"${arr[@]}"` on a zero-element array as `unbound variable` under `set -u`, even for `arr=()`; fixed in 4.4, never shipped on macOS. Every array splat in a mode launcher that CAN be empty at runtime MUST use `"${arr[@]+"${arr[@]}"}"` instead of bare `"${arr[@]}"`. `portable-launcher_test.sh` assertion (20) statically enforces this via grep across all `claude-*.sh`/`pi-*.sh`, with a self-check fixture guarding the filter itself.

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
- **`harnesses/shared/` scripts resolve via `$CODEGEN_DIR`, not `$SCRIPT_DIR/../shared/`** — installed launchers sit beside a sibling `harnesses` symlink to source; `source "$CODEGEN_DIR/harnesses/shared/<script>.sh"` resolves correctly both in-repo and installed (see `pitch-context-selector.sh`, `experiment-prune.sh`, `mode-context.sh`).
- **Launcher tree-climbing** — Check `OCG_CODEGEN_DIR`, then fallback.

## Runtime Porting — Reduced Fidelity Across Harnesses

When porting a guard/hook from Claude (Bash) to Pi (TypeScript), the runtime capabilities may differ:

- **Transcript access**: Claude has JSONL transcript inspection via `jq` + `TRANSCRIPT_PATH`; Pi has no transcript. Guards depending on transcript-based detection cannot be ported with full fidelity. Write a reduced-fidelity observe-only twin with disk-scan heuristics + explicit header comment documenting the gap.
- **Event blocking asymmetry**: Claude's Stop event can block; Pi's `session_shutdown` is observe-only. All 4 Stop/SubagentStop twins emit stderr warnings, NEVER `block()`.

The goal is truthful hooks that accurately reflect capability limits, not feature parity claims that hide missing capabilities.

## Trigger Keywords

claude-build, claude-debug, claude-shape, pi-build, dispatch.sh, launcher, system prompt, modes, tools-header, new launcher mode, claude-ops, pi-ops, claude-babysit, pi-babysit, babysit mode, drain supervisor, CLAUDE_ROLE, per-mode hook bypass, claude-experiment.sh, harness-parity launcher tests, operator vs batch divergence, runtime porting, reduced fidelity, transcript access, event blocking asymmetry, context_files, mode-context, ROLE_CONTEXT_FILES, resolve_mode_context, mode declared context, FIFO stderr capture, process substitution, stdout transparency, jumpstart, break-glass, incident recovery, explicit operator entry
