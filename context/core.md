# Core Domain — Manifest + Generator Pipeline

The core domain owns the manifest schema, generator pipeline, and install/uninstall lifecycle. Every harness is described by a `manifest.yaml`; `generate.sh` renders agent prompts from `.md.j2` templates; `install.sh` reads the manifest and runs declared install steps.

Data flow: `manifest.yaml` → `generate.sh` (renders via `process_template.py`) → `templates/generated/<harness>/` → `install.sh` → `~/.claude/`.

## Key Modules

| Module                                        | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `templates/generator/generate.sh`             | Entry — renders `.md.j2` templates for a named harness                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `templates/generator/process_template.py`     | Jinja-style `{% include %}` processor; inlines rule/recipe files                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `templates/generator/hook_registrations.py`   | Generates `settings.json` hook entries from the hook source dir (single user_global surface)                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `templates/generator/enforcement_compiler.py` | Generates enforcement hook scripts (bash + TS) from `shared/enforcement/registry.yaml`                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `templates/generator/manifest-lib.sh`         | Bash lib wrapping `yq` for manifest field extraction                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `templates/generator/config.yaml`             | Role → model/effort/tools/thinking_tokens mapping; read by `load-role.sh`                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `templates/generator/test_dual_render.sh`     | Self-test: renders both harnesses and diffs output for regressions                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `templates/generator/test_fixtures/`          | Fixture `.md.j2` templates used by generator self-tests                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `harnesses/claude/manifest.yaml`              | Claude harness install contract (agents, hooks, launchers, modes)                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `install.sh`                                  | Per-harness install via `for _harness in "${HARNESSES[@]}"` loop with `case "$_harness" in` dispatch; reads manifest for PATHS, hardcodes its own step order directly (the manifest's `install_steps:` field is declared but read by nothing). Renders user-app AGENTS/CLAUDE docs from fixed `APPS_SRC_DIR="$CODEGEN_DIR/shared/apps"` into overridable `APPS_OUT_DIR="${OCG_RENDERED_APPS_DIR:-$APPS_SRC_DIR}"` (mirrors `OCG_GENERATED_DIR`); a missing `.j2` source is now a fatal error, never a warn-and-skip |
| `uninstall.sh`                                | Removes installed artifacts; hardcodes its own removal order directly — does NOT read manifest `uninstall_steps:`                                                                                                                                                                                                                                                                                                                                                                                                   |
| `codegen-build`                               | Top-level launcher: requires --harness flag; delegates to harnesses/<harness>/dispatch.sh, which runs the Elixir loop with byte-transparent stdout and portable FIFO-based stderr capture (no `/dev/fd` process substitution)                                                                                                                                                                                                                                                                                       |
| `codegen-scaffold`                            | Downstream app scaffolder: renders `shared/scaffold/` templates into a new project dir                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `codegen-call`                                | One-shot structured LLM call binary: requires --harness (exits 2 if missing); unknown flags exit 2 (fail-loud); no --role flag                                                                                                                                                                                                                                                                                                                                                                                      |
| `config.sh`                                   | Shared env/path config sourced by all scripts                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `resource_manager.sh`                         | Manages port allocation across OCG projects system-wide via ~/.ocg/resources.json                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `utils.sh`                                    | Common bash utilities: OCG_CMD invocation                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `update_ai_tools.sh`                          | Post-install: updates Claude CLI and AI tool deps                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

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

| Launcher           | Purpose                                                                                                                                                                                                                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `codegen-build`    | Default agent build launcher — requires `--harness` flag (exits 2 if absent); delegates to `harnesses/<harness>/dispatch.sh`, which execs `claude` directly with model/effort/tools flags; skips integrate pre-step on self-builds (when `$CWD == $SCRIPT_DIR`) to prevent re-symlinking AGENTS.md/CLAUDE.md |
| `codegen-scaffold` | Downstream app scaffolder — two subcommands: `codegen-scaffold create --stack=... --cwd=... --slug=...` (full scaffold) and `codegen-scaffold integrate --stack=... --cwd=... [--slug=...]` (symlinks only)                                                                                                  |
| `codegen-call`     | One-shot structured LLM call binary — requires `--harness` (exits 2 if missing); unknown flags exit 2 (fail-loud); requires `--model`, `--effort`, `--system-prompt @<path>`; no --role flag                                                                                                                 |

Routing flow: `codegen-build` → `harnesses/<harness>/dispatch.sh` → reads `config.yaml` directly via `yq` (NOT via `load-role.sh`) → execs launcher with model/effort/tools flags. `load-role.sh` is used only by debug/shape/refactor/ops launchers, not build dispatch.

**`codegen-build --effort=<e>`** is a LIVE one-build override (not advisory) — validated against the canonical enum in `harnesses/shared/effort-canonical.sh` (`off|low|medium|high|xhigh|max`, exit 2 on unknown), exported as `CODEGEN_BUILD_EFFORT`, threaded by both `dispatch.sh` twins into an explicit `--effort=<e>` argv entry to `mix codegen.loop`, and applied by `OrchestrationLoop.invoke_role/4` to every role's effort UNLESS a fixed campaign binding (benchmark harness) pins that role. `codegen-build --model=<m>` remains advisory/dead — only `--effort` and `--fallback-model` are live overrides. `codegen-call --effort=<e>` is validated the same way before being translated per-adapter: claude omits `--effort` entirely for `"off"` (relies on the ambient `MAX_THINKING_TOKENS=0` env already set) and passes `--effort <value>` otherwise. Full precedence + telemetry contract: `context/role-config.md` § Canonical Effort Vocabulary + Build-Wide Override.

Enforcement compiler (registry schema, pattern dialects, renderer-neutral tokens, install workflow): → see `context/enforcement-compiler.md`.

## codegen-call Arg-Parsing + call-dispatch.sh Flag Threading

`codegen-call` is a pure bash arg-parser + env-exporter that DOES NOT exec the LLM binary directly. It parses all flags, validates required ones, and EXPORTS them as `CODEGEN_CALL_*` env vars, then returns (allowing dispatch stubs to read the env). `harnesses/<harness>/call-dispatch.sh` reads those exports and builds the final executable argv. This two-stage design maintains a **one-way knowledge boundary**: codegen-call MUST NOT know about `--agent` value semantics or role names; it accepts any non-empty string as a passthrough and exports it. Callers (Elixir orchestration loop) supply role identity via the `--agent` flag; `call-dispatch.sh` routes it natively to `claude --agent <role>`.

**Architecture requirement**: codegen-call's arg parser must NEVER hardcode a role name or reference `--append-system-prompt`. Tests enforce this via regex assertions:

- Test (o) in `codegen-call_test.sh` (the role-name-token assertion) — asserts source has ZERO role-name tokens (`developer|committer|reviewer|curator`; `committer` kept in the regex as a defensive check against reintroduction even though it is no longer a role)
- Test (p) (the --append-system-prompt-token assertion) — asserts source has ZERO `--append-system-prompt` tokens

These tests block any regression that would hardcode role knowledge into codegen-call's source. The `--append-system-prompt` flag lives ONLY in `call-dispatch.sh` (`:56`, conditionally omitted when `CODEGEN_CALL_AGENT` is set); codegen-call never exports it.

**Flag threading pattern** (mirrors existing `CODEGEN_CALL_SETTINGS_PATH`, `CODEGEN_CALL_EXTENSION_PATH`):

1. `codegen-call --agent=<role>` parses the flag and exports `CODEGEN_CALL_AGENT="<role>"`
2. `call-dispatch.sh` reads `AGENT="${CODEGEN_CALL_AGENT:-}"` in its env-read block
3. When `AGENT` is non-empty, the COMMON_FLAGS builder appends `--agent "$AGENT"` and OMITS the `--append-system-prompt` line
4. When `AGENT` is empty (non-agent-mode), the append flag is present (legacy path)

This design lets codegen-call stay a generic boundary layer: it parses flags but never interprets them, allowing new features (like `--agent`) to pass through without modifying codegen-call's semantics or test boundary assertions.

**`--resume` mirrors `--agent` exactly**: `codegen-call --resume=<sid>` parses and exports `CODEGEN_CALL_RESUME="<sid>"` with zero validation — same generic-boundary pattern. `harnesses/claude/call-dispatch.sh` reads `RESUME="${CODEGEN_CALL_RESUME:-}"` and appends `--resume "$RESUME"` to `COMMON_FLAGS` when non-empty. Sessions now persist by default — `--no-session-persistence` was removed from `COMMON_FLAGS` so every codegen-call session writes to `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` and is resumable. The envelope carries the session id at `.session_id` (extracted from the stream-json `result` event's `.session_id` field), so a caller can capture it and pass it back via `--resume` on a follow-up call to warm-resume the same session (the role remembers its prior work). **Correction (prior text had this backwards)**: only 1 of Claude's 4 envelope builders (the normal-completion success path) emits a real `session_id` from the stream-json result event — the other 3 (early-exit/schema-invalid paths) hardcode `null` even when a session may exist, a real gap on the warm-resume path. ALL 4 builders emit `session_id` from `$EFFECTIVE_SESSION_ID` (resolved as `RESUME` → `SESSION_ID_ARG` → `MINTED_SESSION_ID`, coalesced to `null` only when all three are empty). Full asymmetry inventory → `context/call-contract.md`.

**`metrics` envelope block (tool-trace summarization)**: `call-dispatch.sh` captures the FULL stream-json/JSONL trace into `TMP_OUT` before extracting the terminal result event; historically every `assistant`/`user` tool_use/tool_result event in that trace was discarded once the temp file was deleted at `EXIT`. `_summarize_metrics()` runs one additional `jq` pass over `TMP_OUT` (same on-disk file, no new claude invocation) and attaches the result as a top-level `metrics` key on the envelope — **success envelopes only**; a failed/schema-exhausted/watchdog-stall/no-result envelope carries no `metrics` key at all (a faked zero on an abnormal call is exactly the green-on-empty defect this exists to fix). Schema:

- `read_count` / `edit_count` / `write_count` / `bash_count` — always present (0 when the trace has no tool events); `edit_count` folds `Edit` + `MultiEdit`
- `tool_counts: {<tool> => <n>}` — present only when at least one tool_use/tool_execution_end event exists; OMITTED (not `{}`) on an empty trace
- `read_edit_ratio` — present only when `edit_count > 0` (division is undefined at 0; OMITTED, never `null` or `0`)
  **`--session-id` mirrors `--resume`/`--agent`**: `codegen-call --session-id=<sid>` parses and exports `CODEGEN_CALL_SESSION_ID` with zero validation. Pins a NEW (cold) call to a caller-minted id so a LATER transient-retry `--resume` can recover it even if the process is killed before it ever reports its own session id (a mid-response drop never emits a `result` event, so the envelope's `.session_id` is unreachable on that path — the caller must mint up front instead). `harnesses/claude/call-dispatch.sh`: `--resume` wins if both are set, else `--session-id` is appended. Consumer: `OrchestrationLoop.do_invoke_attempt/6` mints via `mint_session_id/0` before every cold attempt-start (see `context/test-harness.md` § Warm-resume on transient retry).

## Prompt-Body Duplication and Sibling Synchronization

When a pitch names N source files for extension but the load-bearing text is duplicated across (N+1) siblings that feed the SAME generated artifact, this is a **Rule-J parallel case**. Example: `shape.txt` extension to the Unverified-empirical-claims blocker also requires parallel updates to `_probing.txt` (same shape system prompt sink via `manifest.yaml` modes: `prompt_body = [shape.txt, _probing.txt, ...]`). Both files appear in the same rendered output; editing only the pitch-named N files leaves split-brain generated prompts.

**Treatment**: Include the (N+1)th sibling in the edit scope with a documented assumption of parallel scope widening. Do not silently honor the literal file-count constraint if it means shipping contradictory generated output.

**Parity-test sentinels**: the `prompt-content-parity_test.sh` file uses fixed-string grep assertions to verify baked prompt content. When extending a blocker like Unverified-empirical-claims with new probe lists or detection logic, audit whether sentinels exist for the old prose. If sentinels exist (e.g., `ASK-GATE: product forks only`, `INTERACTION-AUDIT: compose-check siblings`), confirm they still appear in the new blocker text. If no sentinels exist for the new rules (e.g., spread-technique or composition-check wording), no sentinel sync is required — parity coverage applies only to text already under test.

## Manifest Schema

Each harness declares its full installation contract in `harnesses/<harness>/manifest.yaml`. This is the single source of truth for install behavior — `install.sh` and `uninstall.sh` read it to drive every step.

| Field             | Type   | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ----------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `harness`         | string | Harness identifier (`claude`)                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `agents_dir`      | path   | Install destination for rendered agent `.md` files                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `generator`       | path   | Script that renders `.md.j2` templates → agent files                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `settings_file`   | path   | Target settings JSON on developer machine                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `settings_source` | path   | Source settings JSON in repo                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `hooks_dir`       | path   | Install destination for hook scripts                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `hooks_source`    | path   | Source hook scripts directory                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `launchers`       | list   | `{name, src}` pairs — scripts COPIED (not symlinked) to `$INSTALL_DIR` via `content_stable_cp`; each installed copy derives `CODEGEN_DIR` from its own location (`$INSTALL_DIR`), so it cannot reach anything outside `harnesses/`/`shared/` without a sibling symlink. `install.sh` plants four such siblings in `$INSTALL_DIR`: `harnesses`, `shared`, `templates` (needed by `codegen-document`'s INDEX regeneration), `analysis` (needed by `codegen-analyze`'s Python package) |
| `completions`     | list   | Zsh completion script names to install                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `modes`           | map    | Per-mode config: `model`, `effort`, `output_format`, `tools`, `system_prompt_file`, `tools_header`, `prompt_body`                                                                                                                                                                                                                                                                                                                                                                   |
| `install_steps`   | list   | Declared, but read by NOTHING — `install.sh` hardcodes its own step order instead. Dead schema field (confirmed by full-vocabulary grep; do not rely on it to determine install order)                                                                                                                                                                                                                                                                                              |
| `uninstall_steps` | list   | Declared, but read by NOTHING — `uninstall.sh` hardcodes its own step order instead. Dead schema field, same as above                                                                                                                                                                                                                                                                                                                                                               |

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

## install.sh Shell Redirect Gotcha

When gating install steps with a subshell in `install.sh`, the shell construct `if (subshell) 2>&1` places the `2>&1` redirect on the **outer `if` compound command, not inside the subshell.** The redirect is a no-op; subshell stderr still flows to the terminal. Example: `if (npx playwright install chromium) 2>&1` captures NO output from playwright — redirect is applied after the `if` statement completes, not during subshell execution. Pattern: move the redirect INTO the subshell: `if (npx playwright install chromium 2>&1)` or use a separate context: `( npx playwright install chromium 2>&1 )` at the call site. This pitfall commonly appears in conditional Chromium installation steps (cf. session 20260608_153448).

## Stale Generated Artifacts

Some generated system-prompt files may become stale and stay in the repo as legacy:

- `claude-refactor-system-prompt.txt` — no corresponding `refactor` mode in `config.yaml` or manifest; no `system_prompt_file` points at them; NOT regenerated by `make install`. Safe to leave untouched; they are orphaned from earlier design. If deleting, verify no role-def templates or hooks reference them (should be zero hits in `grep -r` across `shared/` and `harnesses/`).

## Architectural Constraints

**One-way knowledge boundary**: Codegen MUST NOT know about, name, or validate downstream consumer projects. Codegen installs artifacts into `~/.claude/` only; if a consumer symlink is stale or if the consumer's own setup validation fails, that failure happens in the consumer's build (the right place). Codegen does not own consumer validation. This keeps codegen focused on generator mechanics and prevents coupling to downstream-specific paths or concerns. Any cross-consumer validation logic (e.g. drift-guard) violates this boundary and should be removed.

(See `context/enforcement-compiler.md` for renderer-neutral regex tokens details.)

## Config as Single Source of Truth

Shell launcher + Elixir runner read same config keys. Two configs for one component (`harness.build.claude` AND `roles.build`) → silent drift. One canonical path. Both consumers read it. Rename → grep all, update together. ❌ Duplicate model/tool per consumer ✅ Shared key, consumers reference.

## Update When Changing

Load this file when touching: `manifest.yaml`, `generate.sh`, `process_template.py`, `hook_registrations.py`, `enforcement_compiler.py`, `install.sh`, `uninstall.sh`, `codegen-build`, `codegen-scaffold`, `config.sh`, `resource_manager.sh`, `utils.sh`, or `shared/enforcement/registry.yaml`.

## Loop Role Invocation

The Elixir `OrchestrationLoop` (`test_harness/lib/codegen_test_harness/orchestration_loop.ex`, `guard_bundle_flag!/2`) invokes each role via native `claude --agent <role>` + the FULL committed `harnesses/claude/claude-code-settings.json` — the same settings file the legacy (non-loop) path loads. `--agent <role>` stamps `.agent_type` natively (the installed `~/.claude/agents/<role>.md` supplies system prompt + tools), so AGENT_TYPE-gated role guards (reviewer/curator/developer) and the two orchestrator confinement guards (which bypass on either `agent_id` OR `agent_type`) apply exactly as they do under a real subagent spawn. There is no reduced hook subset — the loop and legacy paths share one settings.json. The deterministic commit step (`codegen-commit`) is a script the loop shells directly, not an `--agent` invocation, so it carries no `AGENT_TYPE` at all.

## Pitfalls

- **Split extraction: verify load-bearing, not meta** — Extractors pull EOF by default. Stop boundary BEFORE trailing meta. Verify last H2 is terminal cluster, not footer.
- **`make install` registry/settings.json parity** — Changing registry `event`/`tool_guard`/`role` requires bootstrap: `hook_registrations.py --output-settings` BEFORE `make install`. New-file additions skip bootstrap.
- **`manifest_regenerate_prompts` file check** — new prompt-source `.txt` files must exist before `make install`. Gate's install round-trip catches missing files.
- **yq binary must be mikefarah, not python-yq** — wrong binary causes silent manifest parsing errors.
- **`npm install` at codegen root required** — absent → hooks emit INCONCLUSIVE.
- **`make install` required after rule/template change** — regenerates baked prompts; parity gates do not catch stale bakes. Workflow: edit → `make install` BEFORE `make test`.
- **`mise trust` runs unconditionally on install** — no interactive prompt.
- **config.yaml anchoring** — Multiple blocks may share leaf values; include surrounding context. Verify via `yq` post-change.
- **`process_template.py` include/if ordering** — includes run AFTER if-stripping, breaking fragments. Fix: move to TOP before if-stripping.
- **Fragment whitespace** — Whitespace around `{% include %}` determines output blank lines; trailing-newline must match exactly.
- **Non-contiguous regions** — Use separate fragments, one per region; not single-file multiple-includes.
- **install.sh fatal-exit composition** — New guards compose without reordering; non-fatal stderr observed-only.
- **Coupled-flag deletion: all callers must drop both flags** — Dropping one flag forces all callers to drop ALL coupled flags.
- **`manifest_regenerate_prompts` requires FULL mode block deletion** — Cannot null out just system_prompt_file; must delete the entire mode block or regen errors.
- **Env var leakage in tests** — Tests exercising DEFAULT branches must `env -u VAR bash` to isolate. Single `env -u` leaves fallback.
- **Session-log order-check H1-rank false-positives** — Order-check algorithms must be H2-scoped (`##` prefix only). Ranking H1 lines (e.g., `# hook-name` in code blocks) causes false "rank decreased" denials.
- **`Kahn algorithm`: edge direction** — Edge `SLUG -> DEP` = "SLUG blocked by DEP" (DEP executes first). Confusion between "depends on" vs "is depended on by" causes wrong sort.
- **`parse_edges` multi-dep pitfall: captures only first dep per line** — Naive line-split + first-token extraction on legacy `Blocks-on: a, b, c` prose gets only `a`. Always iterate ALL comma/space-separated tokens (the prose fallback path deliberately keeps this first-dep-only behavior — matches `build-queue.sh`'s historical behavior). The frontmatter `blocks_on: [a, b, c]` flow-list path (dual-read first choice) parses ALL list items via comma-split for BOTH inline and multiline forms — `extract_frontmatter_key/2` (shared by `blocks_on:` and `scope:`) collects continuation lines up to the next top-level `key:` line or block end, assembles them, then the flow-list parser splits on commas and yields all items. This is load-bearing for `scope:`, whose only hand-written instance is multiline (8+ paths rarely fit inline) — see `LoopQueue.parse_scope/2`.
- **Byte-cap trimming** — Measure before appending; trim stale bullets to make room.
- **Death markers are a typed JSONL event, not a markdown header** — corrects a stale prior model of "H3 death-stamp inserted into a markdown section body." The cycle log is append-only JSONL with no headers/sections at all; a death is `{"ev":"died","role":<r>,"kind":"interrupted"|"aborted",...}`, written via `codegen-log append <role> --died <kind>` — see `shared/rules/_core/session-log.md` § Death Stamps for the full contract.

## Trigger Keywords

manifest.yaml, generate.sh, harness install, install.sh, hook_registrations.py, codegen-build, codegen-scaffold, codegen-call, generator pipeline, manifest schema, guard_bundle_flag, config single source, yq mikefarah, npm install root, mise trust, install.sh fatal-exit, process_template include ordering, FIFO stderr capture, process substitution
