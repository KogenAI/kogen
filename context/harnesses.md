# Harnesses Domain — Claude Harness Specifics

The harnesses domain covers the per-harness launcher scripts, dispatch logic, mode definitions, system prompt assembly, and settings files. Each harness (currently Claude Code only) has its own directory under `harnesses/` with a manifest, launcher scripts, system prompt `.txt` files, `tools-header/` fragments, and a `dispatch.sh` that selects mode and invokes the underlying CLI.

System prompt assembly: `tools-header/<mode>.txt` + entries in `prompt_body[]` (manifest order) → `<harness>-<mode>-system-prompt.txt` via `manifest_regenerate_prompts()`. Empty files in prompt_body are skipped.

## Components

| File / Dir                                                | Purpose                                            |
| --------------------------------------------------------- | -------------------------------------------------- |
| `harnesses/claude/claude-{debug,experiment,shape,ops}.sh` | Mode launchers                                     |
| `harnesses/claude/dispatch.sh`                            | Mode dispatcher                                    |
| `harnesses/claude/load-role.sh`                           | Runtime config reader (shape/ops/debug/experiment) |
| `harnesses/claude/tools-header/`                          | Per-mode prompt headers                            |
| `harnesses/claude/claude-code-settings.json`              | Hook/permission config (source)                    |
| `harnesses/shared/prompt-bodies/`                         | Shared prompt body                                 |
| `shared/prompt-fragments/`                                | Reusable fragments                                 |
| `harnesses/claude/commands/`                              | Slash commands (`.md.j2` templates)                |

## Dispatch & Session Re-Attach API

**Claude re-attach flag**: `claude --resume <id>` (full or partial UUID). Valueless `--resume` opens interactive session picker. Dispatch MUST emit `--resume "$id"` only when id is non-empty; never emit valueless flag.

**One-shot launcher boundary**: `claude-ops.sh`, `claude-shape.sh`, `claude-debug.sh`, `call-dispatch.sh` are single-invocation (Claude sessions persist by default now, no opt-out flag). `codegen-build`/`dispatch.sh` has no resume flags — always runs the Elixir loop (job-controlled, non-exec, via the shared `harnesses/shared/loop-signal-bridge.sh` helper; see § Orchestrated Build Mode).

**`call-dispatch.sh` optional transcript capture**: `call-dispatch.sh` honors an optional `CODEGEN_CALL_TRANSCRIPT_PATH` env var — when set, the captured stream-json is copied there on the EXIT trap before the temp file is deleted (fail-loud-non-blocking: a copy failure prints to stderr but never changes the exit code); unset = current behavior (no copy). Consumed by the Elixir orchestration loop for durable per-role transcripts; see `context/test-harness.md` § Orchestration Loop.

## Consumer Role Definition

A role = one `codegen-call` invocation. Identity flags: `--system-prompt` (REPLACE = whole identity), `--model`, `--effort`, `--harness`, `--allowed-tools`, `--settings @<path>` (claude enforcement bundle). No role name is hardcoded; a consumer defines an arbitrary role with these flags and ZERO codegen change. One-way boundary: `codegen-call` never references a consumer role name.

## Key Paths

```
harnesses/claude/
  claude-build.sh, claude-debug.sh, claude-experiment.sh, claude-shape.sh, claude-ops.sh, claude-babysit.sh
  dispatch.sh, load-role.sh
  tools-header/{debug,experiment,shape,ops,babysit}.txt  ← disk path uses hyphen
  claude-code-settings.json
  commands/
harnesses/shared/prompt-bodies/
  debug.txt      ← Protocol + Allowed Queries + Forbidden + Refusal & Pivot (shared)
  experiment.txt ← single-agent, source-writable, worktree investigation (shared)
  shape.txt      ← Cold-start + Pitch Readiness Check (shared)
  shape-draft.txt ← Capture-append mode prompt (NOT baked via manifest; read directly by launchers for --draft flag)
  ops.txt        ← Rule 1-5 procedural ops rules (shared)
shared/prompt-fragments/
  _probing.txt         ← Inline Probe Discipline section (included in shape + /ready)
  _authoring-spine.txt ← Phase 0 (9-step), Multi-turn, Adjacent, Output Contract, Rules, Anti-patterns
```

## Mode Launcher Cloning Pattern

Clone existing launcher: swap role name, log prefixes, mode-specific flags (e.g., `--worktree`). Two config blocks REQUIRED: `roles.<mode>` (load-role.sh) + `harness.<mode>.claude` (yq). NOT redundant — both committed. Update the manifest's `modes.<mode>` + launcher/completion registration + tools_header/prompt_body refs. All `.txt` files must pre-exist; `manifest_regenerate_prompts()` exits non-zero if missing.

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

| Mode  | tools-header contains (per-harness)                                                         | prompt_body list (shared)                                                                                         |
| ----- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| debug | `## Tools` + harness-specific tool list + FORBIDDEN list + cross-repo grep allowance        | [harnesses/shared/prompt-bodies/debug.txt] — no-cat-pipe line + Protocol + Forbidden + Refusal & Pivot            |
| shape | `## Tools` + harness-specific tool bullets (claude: Agent/Skill/AskUserQuestion/Write-Edit) | [harnesses/shared/prompt-bodies/shape.txt, _probing.txt, _authoring-spine.txt]                                    |
| ops   | `## Tools` + harness-specific per-tool bullets                                              | [harnesses/shared/prompt-bodies/ops.txt] — starts with Cold-Start Opening block, followed by procedural ops rules |

**Placement checklist**:

- **→ per-harness header**: Harness-specific tool names; launcher flags; install paths; protocol names
- **→ shared body**: Neutral tool discipline; orchestration rules; commit hygiene; harness-agnostic behavior

**Fragment paths** in manifest are relative to `CODEGEN_DIR`. The `manifest_mode_get` function returns scalars; `prompt_body` uses `yq '.modes.<mode>.prompt_body[]'` to enumerate the list.

**Prompt-body assembly mechanism**: `manifest_regenerate_prompts()` in `manifest-lib.sh` concatenates all `prompt_body[]` entries verbatim via `cat`, producing the baked `*-system-prompt.txt` files. No Jinja processing, no deduplication. Order affects the byte sequence in the baked prompt (entries are concatenated in list order).

**Per-harness vs shared bodies**: All modes use `harnesses/shared/prompt-bodies/`. Per-harness body dirs no longer exist. Shape appends shared fragments (`_probing.txt`, `_authoring-spine.txt`). SSH context for debug/ops injected via `--append-system-prompt`, not baked. Shared body files in both manifests → one edit bakes both harnesses at `make install`.

**Sentinel propagation**: Sentinels in `prompt_body[]` or appended fragments reach the baked prompt. Shape feeds two sources; sentinels in either propagate. Duplicates in baked prompt are harmless for presence tests.

**Shape investigative disciplines**: Shape mode includes `_authoring-spine.txt`, encoding readiness-loop gates (context load → investigation → readiness check). Spine enforces ten core rules (A–J); A–H (intent-guard, plain-language, command-pairing auto-cover, dedup, symptom-vs-target, context-drift auto-cover, decompose-then-split, derive-and-write edges) live in `_authoring-spine.txt`; I/J (ask-vs-decide, deferral-with-draft) live in `shaper-discipline.md`. Also enforces deletion-safety blockers: rabbit holes, untraced edit surface, dangling refs. See `context/subagents.md` § Authoring Spine Rules. Intent-guard (A) patched into empirical-claim option-(b) in `shape.txt`.

**Shaper ask-vs-decide classifier (I)**: Ask only when answer changes product behavior. Never-ask: tools, models, env, naming, placement. Auto-decide engineering choices; record `Assumed: key=value`. Sibling of `shaper-discipline.md` § Ask-vs-Decide Classifier.

**SSH target resolution paths (ops/debug launchers)**: `resolve_ssh_target()` in `ssh-target.sh` has three outcomes: (1) **HIT** — candidate alias found in `~/.ssh/config`; (2) **MISS-save** — bare unresolvable IP typed; saved as new Host under candidate alias; (3) **MISS-existing** — user typed an alias defined in config but differing from candidate (deliberate choice). Third path MUST connect via `$user_alias` (real Host), NOT `$candidate` (no Host block there). All paths export `${prefix}_ALIAS`; empty falls back to `server_resolved` (bare IP) so launcher self-checks (`ssh ${DEBUG_ALIAS}`) stay well-formed. Tests: `T-new-11` (HIT), `T-new-12` (MISS-save), `T-new-13` (MISS-existing).

**Shared body relocation pitfall** — avoid NEW section headings when relocating lines. Even sensible headings cause false-positive diffs caught by post-relocation assertions. Keep structural headings in headers; move only prose. Example: `## FIRST-TURN PROTOCOL` stays in headers; prose bullets move to body. Heading structure remains per-harness.

**Fragment references in shared bodies** — `_authoring-spine.txt` references `~/.claude/settings.json` as a debugging target for enforcement-bug investigation. This is SHARED investigative discipline. Distinction: `~/.claude/hooks/` / `orchestrator-no-source-edit.sh` are Claude-only; `~/.claude/settings.json` as inspection target is cross-harness (keep in shared).

**Deferral-with-draft contract**: Every deferral MUST be backed by real `codegen/pitches/draft/<slug>.md`. Prose-only deferral = blocker. Security/safety deferrals must state exposure assumptions. A CONCRETE, path-bearing deferral additionally gets a bilateral `handoffs:` record in both pitches (never prose alone) — see `context/pitch-lifecycle.md` § Frontmatter Schema.

**Decompose-then-split rule** (Rule G): SPLIT multi-surface problems into independent pitches (eng-decomposition, not user choice). Only product forks reach user. Before writing, rule G runs the one-clause test (rule H outcome (e)) itself: one-purpose pieces collapse into one pitch, never split; a surviving split records `split_subject: A; B` per sibling — `mix codegen.pitches.scope --check` fails an unproven SUBSUMED pair.

**Derive-and-write dependency edges rule** (Rule H): DERIVE dependency edges from code and WRITE them into the pitch's `blocks_on:` YAML frontmatter flow-list (dual-read fallback: legacy `Blocks-on:` prose); omitted edges → silent mis-order. Auto-derive; ask only on circular/ambiguous cases.

## Multi-Pitch Protocol

Multi-pitch handling (`--queue`) is owned entirely by the Elixir loop's `mix codegen.loop.queue` (`CodegenTestHarness.LoopQueueDrain.drain/1`) — see `context/test-harness.md` § Orchestration Loop for the topo-sort, `blocks_on:` pre-check, and per-pitch sequencing contract. The babysit mode's tools-header + shared prompt-body name the drain dispatch command (`codegen-build --queue --watch`); no OTHER per-harness tools-header carries queue prose.

**Pitch-format contract**: `shape.txt` and `ops.txt` specify EXACT grammar for `## Questions` / `## Answers` in headless mode. Machine-parseable; enforced by `pitch-format-validator.sh` Stop hook (shape/ops). Grammar: `### Q<n>:` + ≥2 `- **<letter>)**` options; `## Answers` references matching Q headings; `status:` (YAML frontmatter, dual-read fallback: legacy `> Status:` blockquote) ∈ {SKELETON, SHAPING, SHAPED}. `/document` writes `status: SKELETON` in frontmatter. Shape advances to SHAPING/SHAPED and persists a `summary:` field at SHAPED.

**Slash commands**: Templates in `harnesses/claude/commands/*.md.j2` rendered by `generate.sh` → `templates/generated/claude-code/commands/` → installed to `~/.claude/commands/`. Can spawn swarms (e.g., `/poke-holes`). Gated by `operator-subagent-allowlist.sh` to {debug, shape, ops}. Examples: `/ready`, `/poke-holes`.

**Ready command source isolation**: `ready.md.j2` includes ONLY `_probing.txt`, NOT `_authoring-spine.txt`. Spine-fragment edits don't propagate to `/ready`. Intentional: `/ready` is single-turn; spine encodes multi-turn shape loop.

**Empirical-claim probe-list homes**: (1) canonical `_probing.txt`, (2) inline shape.txt, (3) ready.md.j2. Edits land in all three or pitch-scoping fails.

## Dispatcher Routing

`codegen-build` (see `context/core.md`) routes via `harnesses/<harness>/dispatch.sh`, which reads mode config and invokes the harness launcher:

```
claude-build.sh → codegen-build → harnesses/claude/dispatch.sh → execs claude-<mode>.sh with model/effort/tools flags
```

For harness install contract details (agents_dir, hooks_dir, modes, launchers), see `harnesses/<harness>/manifest.yaml` documented in `context/core.md` Manifest Schema section.

## Config.yaml Runtime vs Baked Artifacts

**Key distinction**: `load-role.sh` reads `config.yaml` at _runtime_, NOT at install time. This differs from system prompts, which are baked at `make install`:

- **Shape/ops/debug modes**: Use `load-role.sh` to read `config.yaml` at launcher time. Changes to config.yaml take effect _immediately on next invocation_ — no `make install` required.
- **Build**: has no launcher-side mode config at all — `dispatch.sh` runs the Elixir loop, which resolves model/effort per-role itself.

**Tool allowlist enforcement**: The `--tools` flag passed to the `claude` CLI is populated by `load-role.sh` parsing `roles.<role>.tools[]` from config.yaml. Harness launcher `.sh` scripts gate tool spawning via the `--tools` flag, not system-prompt text. Thus, a new tool added to `config.yaml` → immediately available in shape/ops/debug sessions. Build has no launcher-side mode; the loop resolves per-role tool allowlists itself.

**`--agents` flag — size ceiling**: Passing the full custom-agent set via `--agents <json>` does NOT work — a single argv string is capped at `MAX_ARG_STRLEN` (~128 KB on Linux), and a full `--agents` blob overruns it (confirmed failed on a server). Subagent _availability_ is gated by `operator-subagent-allowlist.sh` PreToolUse hook instead. (Agent-file prompt-prefix caching is separate — see `context/claude-token-mechanics.md`.)

**Consequence**: a claim about uncommitted config.yaml changes (in working tree, not yet staged) must be verified against the actual working tree file — not trusted from pitch state alone.

## Settings Overlay via `--settings` Flag

Claude Code supports a `--settings` JSON flag that provides a command-line scope overlay for user-level settings. This is the ONLY way to override user-scope settings like `MAX_THINKING_TOKENS` in a launcher.

**Settings precedence (highest to lowest)**: (1) Managed (admin), (2) Command-line `--settings '<json>'`, (3) Local `~/.claude/settings.json.local`, (4) Project `~/.claude/settings.json`, (5) User `~/.claude/settings.json`.

**Key fact**: Claude reads settings from the JSON FILE, not process environment. `env -u MAX_THINKING_TOKENS` is inert — environment deletion does not affect the setting. Only a `--settings` overlay beats the user-scope file.

**Use case — thinking tokens**: All 5 Claude modes (debug/shape/experiment/ops/babysit) declare `roles.<mode>.thinking_tokens` (16000) in `config.yaml`; `load-role.sh` fail-loud validates + exports `ROLE_THINKING_TOKENS`. Launchers build `--settings` with `MAX_THINKING_TOKENS` interpolated from that var — never a literal — on BOTH interactive/headless branches, overriding installed global `=0` (one-shot/build calls keep 0). Guard: `harnesses/shared/mode-thinking-parity_test.sh`. `make install` propagates config changes.

**Use case — AFK timeout**: Interactive-only launchers (debug/shape/experiment/ops/babysit) gate `CLAUDE_AFK_TIMEOUT_MS=86400000` on `[[ -z "${CLAUDE_NONINTERACTIVE:-}" ]]` vs auto-continuing at 60s. Interactive adds the AFK key to `SETTINGS_JSON`; headless omits it. `--settings` merges key-by-key with `~/.claude/settings.json`. Headless/build keep the 60s default — must NOT appear in global settings.

**Use case — idle-session monitor**: same branch forks `harnesses/shared/shape-idle-monitor.sh` pre-`exec` (`$$` survives `exec` → REPL PID). Binds to transcript via set-diff vs pre-exec snapshot; ambiguous → fail-silent forever. Polls ~30s: dead PID → self-exit; frozen past `CODEGEN_SHAPE_IDLE_WARN_SECS` (default 600s) + last entry ≠ `assistant` → one bell+banner, re-arms on progress. Warn-only; `CODEGEN_SHAPE_IDLE_KILL=1` opts SIGTERM. Fail-open. Headless: none of this.

## Session Log Protocol

The loop creates the cycle log via `codegen-log init --slug <slug> --stamp <ts>` BEFORE delegating to any subagent — passing its own already-minted `stamp` (naming the run's `cycle_id`/transcript dir), so the log stem equals `cycle_id` and a retry of the same slug mints its own log. Append-only JSONL, not markdown — no header-boundary scan. Each role writes via `codegen-log section <role> --slug <slug>` (stdin body), appending `{"ev":"role","role":<role>,"body":<prose>}`. Full contract: `shared/rules/_core/session-log.md`.

Retrospective capture: `role-retrospective-before-stop.sh` (blocking `Stop`) asserts the stopping role's log carries a non-empty `ev:role` body plus `ev:learned`/`ev:no_learning` — via reader selectors, not markdown scanning. `context-curator` not gated (and the deterministic commit step is a script, not a role, so it is out of scope entirely). Full CLI contract: `shared/rules/_core/session-log.md` § Ownership/Enforcement.

## Worktree Isolation (Native `--worktree`)

`claude --worktree <name>` / `-w` creates `.claude/worktrees/<name>/` on branch `worktree-<name>`. A `WorktreeCreate` hook fully replaces git logic (`.worktreeinclude` disabled). `worktree-create-phoenix.sh` seeds `deps` (symlink) + `_build` (copy, same-commit guard) + allocates a port via `resource_manager.sh`. `worktree-remove-phoenix.sh` releases the port (observe-only). Both events are in `PRESERVED_EVENTS` to survive `make install`.

The create hook is idempotent: a re-run re-attaches an already-registered worktree (skips `git worktree add`, re-allocates a fresh port, rewrites `.env` PORT lines) and attaches an orphaned branch without `-b`. So `claude-experiment <slug>` resumes an existing experiment; pass `--new` to force a fresh worktree (tears down the old worktree + branch first).

**Teardown**: `harnesses/shared/worktree-lifecycle.sh` (`worktree_destroy`) supersedes `experiment-prune.sh`. `worktree_create`/`_reattach` are S5 stubs — exit 2 loud, not silent.

## Integration Points

- **core**: manifest.yaml `modes` section documents model/effort/tools per mode; config.yaml is canonical source; for manifest schema see `context/core.md`
- **subagents**: system prompt files include rendered agent rules baked at generate time
- **hooks**: `claude-code-settings.json` is source for hook registration; `hook_registrations.py` writes the installed version; see `context/hooks.md`

## Orchestrated Build Mode

`dispatch.sh` always runs `mix codegen.loop` — the sole build engine; no engine flag, no TTY auto-detection, no legacy fallback. A successful `codegen-build` run requires BOTH a fresh, loop-owned `build-result.json` (matching the mktemp'd `CODEGEN_BUILD_INVOCATION_ID` the wrapper exported, slug captured from the prompt path before dispatch can ship `ready/<slug>.md`, current HEAD, `status: success`) AND `gate-result.json.verdict == "clear"` — see `context/loop.md` § Interrupted-Cycle Recovery. Checkpoint evidence (`gate-result.json`, `cycle-state.json`) is never eagerly deleted pre-dispatch; only a stale `build-result.json` is cleared.

**Loop-child exit record**: `dispatch.sh` job-controls the spawn through the shared `harnesses/shared/loop-signal-bridge.sh` helper (`run_supervised_loop`; non-exec, `set -m` internally, traps INT/TERM and forwards a group SIGTERM to the child — see `build_signal_handler.ex`), tees child stderr to a bounded (~8 KB) temp file through a named FIFO (never `/dev/fd` process substitution), keeps loop stdout byte-transparent, preserves the loop's own status explicitly, and after the helper returns (`run_supervised_loop ... || exit_code=$?`, never bare — `set -e` would abort on a bare non-zero return) writes ONE `{"ev":"exit","status":<n>,"signal":<n-or-null>,"stderr_tail":<text>}` event via `codegen-log exit`, pinned to whichever log `.active` names if it changed during the spawn; otherwise one stderr note, nothing written. Fail-loud-non-blocking: a `codegen-log exit` failure never changes the propagated `exit_code`. The SAME helper supervises the `--queue` leg of the build launcher (`claude-build.sh`) — see `context/loop-queue-drain.md`.

## Opposite-Provider Advisor

`codegen-advise` wraps `codegen-call` and flips to the OPPOSITE provider (fixed mapping), returning
`{plan, confidence}`. Registered in the manifest's `launchers:`. Reach: loop's `maybe_advise/5` at
give-up (`context/loop.md` § Opposite-Provider Advisor) + role-less `advise`/`mcp__codegen__advise`
tool. Failure additive, never a gate.

**DORMANT**: only one provider is installed, so there is no opposite row to flip to. Every
invocation reports that and exits 1 without a model call. Both callers already treat a non-zero
exit as additive-failure, so the build is unaffected. Restoring it = add the second provider's row
to the mapping in `codegen-advise` and drop the guard.

## Mode → Declared Context

babysit/ops/debug/shape/experiment each declare loaded context in ONE place: `config.yaml` `roles.<mode>.context_files` (repo-relative paths). babysit: PROJECT_CONTEXT.md, deployment-topology.md, loop-queue-drain.md, pitch-lifecycle.md. ops: PROJECT_CONTEXT.md, deployment-topology.md, port-allocation.md. debug: PROJECT_CONTEXT.md, deployment-topology.md, launcher-hook-matrix.md. shape/experiment: `[]` — named exemption, resolves dynamically via `harnesses/shared/pitch-context-selector.sh` (Tier-0 Always-Load + citation-prioritized Tier-1, cap 6; explicit `context/<name>.md` citation outranks incidental keyword match).

`mode-context.sh` (`resolve_mode_context <mode>`) is sole reader; resolves paths against `$CODEGEN_DIR` (not cwd), exports `ROLE_CONTEXT_FILES`. `load-role.sh` calls it in `load_role()`. Missing declared path → hard `exit 1` naming mode+path.

Claude loops `ROLE_CONTEXT_FILES` into `--append-system-prompt` flags + startup string.

Guard: `mode-context-parity_test.sh` (auto-discovered via `harness-parity`'s `harnesses/shared/*_test.sh` glob).

**Tier-0 `## Always Load` parser contract**: `claude-shape.sh` and `claude-experiment.sh` carry byte-identical Tier-0 loops (any fix here needs both). Each `- <token>` bullet under the app's `PROJECT_CONTEXT.md` `## Always Load` heading is hardened to accept the documented bare-basename form (`- development.md`, matching this repo's own `PROJECT_CONTEXT.md`) AND the backticked/`context/`-prefixed form app authors hand-write (``- `context/development.md` — desc``) — backticks are stripped, a leading `context/` is stripped, and the result must end `.md` or the entry is skipped rather than resolved. Resolution still fails open: a missing (but well-formed) entry warns on stderr and continues. The Tier-1 selector (`pitch-context-selector.sh`, § above) already tolerated both forms — the Tier-0 loops previously didn't, so a hand-authored `PROJECT_CONTEXT.md` entry could silently resolve to nothing at Tier-0 while working at Tier-1.

## Headless Investigative Mode

The Claude investigative/supervisory launchers (`claude-shape`, `claude-ops`, `claude-debug`, `claude-babysit`) honor the `CLAUDE_NONINTERACTIVE` env var. When set to any non-empty value, each launcher builds a `NON_INTERACTIVE_FLAGS` array. **Important distinction**: investigative launchers deliberately restrict `--setting-sources` to `project` (no user-scope agents/hooks) because they export `CLAUDE_ROLE` and gate the Agent tool to project subagents only. Build dispatch (`codegen-build --non-interactive`) uses `user,project,local` to load the full agent set + user-level gating hooks.

**`CLAUDE_NONINTERACTIVE` branch signal**: same condition `[[ -n "${CLAUDE_NONINTERACTIVE:-}" ]]` also gates interactive-vs-headless `--settings` construction in shape/debug/experiment/ops launchers — headless omits `CLAUDE_AFK_TIMEOUT_MS`, interactive adds it — and, in `claude-shape.sh` only, whether the idle-session monitor forks at all. Co-located to stay synced and prevent accidental 24h hangs / stray monitors on headless builds.

Shared flags: `--print --verbose --output-format stream-json --strict-mcp-config --no-session-persistence --disable-slash-commands`. Only `--setting-sources` differs: investigative launchers use `project`; build dispatch uses `user,project,local`.

These flags are spliced as the **first positional** after `exec claude` (before `--model`). `CLAUDE_NONINTERACTIVE` is an investigative-mode toggle, unrelated to the build path (no non-interactive flag at all).

**One-shot semantics**: headless investigative sessions run once and exit. If the agent needs a user decision, it writes a `## Questions` block in-scope and stops; the operator answers via `## Answers`; a fresh session continues.

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

Models decompose multi-step instructions (Edit → Agent) into pick-one alternatives. Fix: name the pair ("spawn ritual"), phrase as ONE atomic op where manual header-Edit + Agent() sequencing still applies (shape/ops/debug). Build path doesn't need this — the Elixir loop invokes each role directly. Reusable: name any strictly-ordered sequence (ritual/ceremony/protocol) as one conceptual op to block decomposition.

## SSH Target Identity Persistence (`harnesses/shared/ssh-target.sh`)

**Location**: `harnesses/shared/ssh-target.sh` (shared). Test: `harnesses/shared/ssh-target_test.sh`.
**Two-identity model**: `ssh-target.sh` persists two user identities in `~/.ssh/config` alias blocks — (1) login user (`User <login>` line), (2) operate-as user (`# ops-operate-as: <user>` comment). Resolver exports `${PREFIX}_LOGIN_USER` and `${PREFIX}_OPERATE_AS` alongside `_SERVER`/`_ENV`.

**Backfill logic**: Alias with `HostName`-only triggers one-time interactive prompt → collects login user (default `root`) + operate-as (optional) → awk block-scoped rewrite via temp-file/mv. Guard: runs only when `User` line absent; idempotent on re-run.

**EOF-safe reads**: use `read -rp "..." var || true; var="${var:-default}"`. Under `SSH_TARGET_NON_INTERACTIVE=1`, all prompts skipped.

**Test-design constraint**: Pipe subshell exports invisible to parent — verify config file contents, not exported vars.

**Integration**: Ops/debug launchers source `ssh-target.sh`. Ops rule body (`prompt-bodies/ops.txt`) concatenated at generate-time into baked system-prompt; inert until `make install`.

## Platform Repo Makefile Targets

The platform (codegen) repo uses `make test` as the gate command, NOT `make ci` (no ci target). Downstream app repos (Phoenix/static) may differ — always verify the Makefile target exists before declaring it as `GATE_COMMAND`. The gate is a per-PROJECT operator declaration in `<project>/.claude/gate-config.sh`, read verbatim by `gate-select.sh`; no role's output can set or override it, and a missing/empty `GATE_COMMAND` yields the fail-loud `__GATE_UNRESOLVED__` sentinel rather than a guessed default.

## Launcher `.sh` Files: Runtime Scripts vs Baked Prompts

**Critical distinction**: Launcher `.sh` files (`harnesses/claude/claude-shape.sh`, `claude-debug.sh`, etc.) are **runtime scripts copied by `make install`**, not baked into system prompts. Edits to launcher flags propagate via the **install process**, not via prompt-content-parity sentinel sync.

**Key implications**:

- Editing the `--settings` flag in `claude-shape.sh` (the `MAX_THINKING_TOKENS` line) → `make install` copies the updated script to `~/.claude/claude-shape` → next invocation uses new budget. No sentinel-sync needed.
- Launcher edits are runtime-effective; they do NOT participate in system-prompt baking or prompt-content-parity verification.
- To verify a launcher flag change took effect: check `~/.claude/claude-<mode>` directly, or run the launcher with `--verbose` to see the exec'd command line.

**Contrast**: System prompt bodies (`harnesses/shared/prompt-bodies/shape.txt`) ARE baked and DO require sentinel sync in `prompt-content-parity_test.sh`.

**Bash 3.2 empty-array splat constraint**: macOS system bash (3.2.57) treats `"${arr[@]}"` on a zero-element array as `unbound variable` under `set -u`, even for `arr=()`; fixed in 4.4, never shipped on macOS. Every array splat in a mode launcher that CAN be empty at runtime MUST use `"${arr[@]+"${arr[@]}"}"` instead of bare `"${arr[@]}"`. `portable-launcher_test.sh` assertion (20) statically enforces this via grep across all `claude-*.sh`, with a self-check fixture guarding the filter itself.

## Shape Launcher `--draft` Flag

The shape launcher (`claude-shape.sh`) accepts a `--draft <path> "text"` flag that activates **capture-append mode**:

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
- **Build dispatch is hermetic** — `dispatch.sh` (both harnesses) runs `mix codegen.loop` via the shared `loop-signal-bridge.sh` helper; unsets API keys; test: `dispatch_test.sh`
- **`prompt_body` is ordered list** — missing entries → non-zero exit
- **Fragment paths relative to `CODEGEN_DIR`** — process_template.py resolves under `$CODEGEN_DIR/shared/`
- **Installed launchers have full `harnesses/` tree** — check `~/.local/bin/harnesses/` to verify dispatch.sh edits propagated
- **`codegen-log section` + developer role** — sets `CLAUDE_ROLE` explicitly to avoid 3-strike gate collision; use Edit tool as workaround
- **`ready.md.j2` is template** — generated by `generate.sh`; never install from source `.j2` directly
- **`harnesses/shared/` scripts resolve via `$CODEGEN_DIR`** — `source "$CODEGEN_DIR/harnesses/shared/<script>.sh"` works in-repo and installed (see `pitch-context-selector.sh`, `ssh-target.sh`, `worktree-lifecycle.sh`, `mode-context.sh`, `loop-signal-bridge.sh`).
- **Launcher tree-climbing** — Check `OCG_CODEGEN_DIR`, then fallback.

## Trigger Keywords

claude-build, claude-debug, claude-shape, dispatch.sh, launcher, system prompt, modes, tools-header, new launcher mode, claude-ops, claude-babysit, babysit mode, drain supervisor, CLAUDE_ROLE, per-mode hook bypass, claude-experiment.sh, harness-parity launcher tests, operator vs batch divergence, transcript access, context_files, mode-context, ROLE_CONTEXT_FILES, resolve_mode_context, mode declared context, FIFO stderr capture, process substitution, stdout transparency, loop-signal-bridge, run_supervised_loop, SIGINT SIGTERM group forward
