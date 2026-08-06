# Hooks Domain — Hook System (Bash + Tests)

The hooks domain covers all Claude Code hook scripts, their shared library, registration mechanism, and bash test suite. Hooks fire on `PostToolUseFailure`, `PreToolUse`, and `Stop` lifecycle events — these are the events codegen currently registers; Claude Code supports a larger event catalog (see § Hook Event Types and Scripts below). No `SubagentStop` hook is registered — the loop runs roles as main sessions, so that event never fires under a build. Each hook has a paired `_test.sh` file; `run-tests.sh` runs the full suite.

**Builds are driven unconditionally by the deterministic Elixir orchestration loop** (`mix codegen.loop`, invoked unconditionally by `dispatch.sh` for every build) — there is no interactive self-orchestrating build session. Because the loop invokes each role as a separate main-agent `codegen-call` (`claude -p --print`), there is NO `SubagentStop` event under the loop. No mode spawns a `developer-*` subagent (`operator-subagent-allowlist` gates subagent spawns to `Explore` only), so no `SubagentStop` hook is registered at all today. PreToolUse hooks fire normally in every per-role session regardless of mode.

Hook registration: **Two pipelines** (`enforcement_compiler.py` for `kind: denial` full-file generation; `hook_registrations.py` for `kind: registration` header-only injection + settings.json generation). Counts (verify): `grep -c 'kind: denial' shared/enforcement/registry.yaml`, `grep -c 'kind: registration'`. Full mechanics (compiler ownership boundary, header/body split, workflow order) → `context/hook-authoring-patterns.md` § Hand-Authored Hook Script Structure & Registration / § Hook Registration Mechanics (this file does not duplicate that detail).

**Not-yet-migrated hooks:** migration complete, no outliers (see `registry.yaml` § NOT-YET-MIGRATED).

**Committing is a deterministic script, not a gated agent role.** `codegen-commit` (repo root) validates the subject, stages via `git add -A`, checks the gate verdict, runs the ported backward-roll guard, and commits — no per-role Bash allowlist hook is needed, because no agent invokes `git commit` at all (`pre-commit-guard.sh` denies it to every role unconditionally). See the pitch "committing is deterministic, not a model call".

**codegen-log write bypass (shared helper)**: command-scanning PreToolUse Bash guards call shared `is_codegen_log_write()`/`isCodegenLogWrite()` (`hooks-lib.sh`/`hook-helpers.ts`) BEFORE any phrase grep. Exemption is invocation-anchored, not spelling-anchored: strips heredoc bodies, then requires the whole command be ONE hard-boundary group (`&&`/`;`/`&`, `|` kept intact) whose stages resolve to a producer (`printf`/`echo`/`cat`) feeding a final `codegen-log` stage. A real `git commit` merely mentioning the token, or a `codegen-log ... && git commit` chain, is NOT exempt. Caller count not load-bearing; enumerate via `grep -rl is_codegen_log_write harnesses/claude/hooks/*.sh`.

## Components

| File | Purpose |
| - | - |
| `harnesses/claude/hooks/pitch-format-validator.sh` | Stop — validates ## Questions/## Answers/status grammar in active pitch for shape/refactor/ops sessions. Status is read from YAML frontmatter `status:` first, dual-read fallback to legacy `> Status:` blockquote. |
| `harnesses/claude/hooks/llm-pending-sweep.sh` | Stop — sweeps for pending LLM-generated artifacts before exit |
| `harnesses/claude/hooks/session-log-writer-only.sh` | PreToolUse — `codegen-log` is the SOLE writer of cycle logs; denies raw Edit/Write/MultiEdit and raw Bash writes into `codegen/logging/*.jsonl` |
| `harnesses/claude/hooks/no-python-json.sh` | PreToolUse — blocks inline `python3 -c` JSON parsing |
| `harnesses/claude/hooks/no-cat-pipe.sh` | PreToolUse — blocks `cat file \| ...` and `head`/`tail` pipe patterns |
| `harnesses/claude/hooks/no-git-stash.sh` | PreToolUse — blocks `git stash` |
| `harnesses/claude/hooks/no-silent-failure.sh` | PreToolUse — hand-authored `kind: registration` content-matcher (mirrors `context-curator-guard.sh` precedent); denies an Edit/Write/MultiEdit whose new content contains a high-precision silent-failure swallow token (empty TS `catch {}`, bare Python `except:`, Elixir `rescue _ ->` without `reraise`, catch-all `_ -> nil\|:ok\|[]\|""` sink); bypassed by `# fail-loud-exempt: <reason>` (reason mandatory) or `reraise` present anywhere in the content. Does NOT gate `\|\| true` — that is reviewer-owned (see `shared/rules/roles/reviewer.md` Rule S). |
| `harnesses/claude/hooks/orchestrator-no-source-edit.sh` | PreToolUse — blocks the main-agent session from editing source files; `experiment` role: exits 0 (confinement via launcher `--worktree`, not path restriction); distinct from `debug`/`shape` read-only arm |
| `harnesses/claude/hooks/orchestrator-no-ci.sh` | PreToolUse — blocks the main-agent session from running CI/test commands |
| `harnesses/claude/hooks/orchestrator-read-discipline.sh` | PreToolUse — blocks the main-agent session from reading files it shouldn't |
| `harnesses/claude/hooks/subagent-read-discipline.sh` | PreToolUse — blocks subagents from reading context files they shouldn't |
| `harnesses/claude/hooks/pre-commit-guard.sh` | PreToolUse — blocks direct `git commit`/staging/history-mutating git for EVERY agent, unconditionally (no per-role exemption — committing is a deterministic script, `codegen-commit`, never an agent action); early codegen-log carve-out (mirrors session-log-writer-only's own pattern) exits allow BEFORE the git-verb scans when the command invokes codegen-log, so role-authored prose piped into a session-log section body is never denied by containing a git-verb token — bare history-mutating git commands remain denied |
| `harnesses/claude/hooks/dev-no-ci.sh` | PreToolUse — blocks developer from running CI commands |
| `harnesses/claude/hooks/developer-no-self-gate.sh` | PreToolUse — blocks developer gate invocation. Loop-mode sig file (3rd line) now also stores `CODEGEN_RESUME_ATTEMPT`; a new resume token vs. last-seen is treated as a fresh first-run (not a same-tree spin) — see "Warm-resume on transient retry" in `context/test-harness.md`. |
| `harnesses/claude/hooks/reviewer-guard.sh` | PreToolUse — reviewer constraint enforcement (Write/Edit/MultiEdit/Monitor deny; Bash no longer gated here — see reviewer-bash-allowlist.sh) |
| `harnesses/claude/hooks/reviewer-bash-allowlist.sh` | PreToolUse — reviewer Bash allowlist (GENERATED): default-deny; permits only `codegen-log` invocations (any position — typically piped, e.g. `printf '%s' "$body" \| codegen-log section --body @-`) plus safe read-only utilities (`git diff/status/log/show`, `echo`, `wc`, `cat`, `ls`, `true`, `:`). No history-mutating git verbs. Fills the Bash gap left when reviewer-guard.sh's Bash hard-deny arm was removed, so reviewers can write their session-log section via codegen-log. **Sandbox constraint**: The allowlist blocks direct invocation of `make`, `python3`, and `grep` — reviewers cannot execute the full `make test` gate directly. Gate-status verification falls back to `git log`/`git diff --stat` cross-checks: verify claimed-unrelated test files are untouched by the current diff and their last-touch commit predates the cycle, rather than re-running the gate. |
| `harnesses/claude/hooks/context-curator-guard.sh` | PreToolUse — guards context file edits to curator role only |
| `harnesses/claude/hooks/curator-context-size-gate.sh` | PreToolUse — denies Edit/Write to `context/*.md` or root `PROJECT_CONTEXT.md` over the 40960-byte cap; hard gate |
| `harnesses/claude/hooks/rule-edit-reach.sh` | PreToolUse, role `*` — advisory (never denies): net-additive Edit/Write/MultiEdit to `shared/rules/**` gets its fan-out + per-prompt overflow via `prompt_size_budget.py --report --path`, delivered as `additionalContext`. Supersedes deleted `context-curator-guard.sh` helper `warn_if_over_cap` (stderr — unreachable by the model). |
| `harnesses/claude/hooks/context-factcheck-edit-gate.sh` | PreToolUse (Edit\|Write\|MultiEdit, role: `*`) — denies ANY role's write to an orientation doc on a projected-content factcheck violation; superseded `context-factcheck-curator-stop.sh` + `context-factcheck-guard.sh`; full detail below in this same section |
| `harnesses/claude/hooks/operator-subagent-allowlist.sh` | PreToolUse — enforces agent delegation allowlist (role ∈ {debug, shape, ops}); gates slash commands that spawn subagents |
| `harnesses/claude/hooks/build-agent-app-confinement.sh` | PreToolUse — denies Write/Edit/MultiEdit outside CODEGEN_BUILD_CWD; role-agnostic; /tmp escape hatch; canonicalizes macOS /var↔/private/var; fills orchestrator-no-source-edit.sh subagent gap |
| `harnesses/claude/hooks/build-worker-cwd-guard.sh` | PreToolUse — guards build worker cwd discipline; whitelist honors optional `OCG_PHOENIX_SEED_DIR` and `OCG_USER_FILES_DIR` (consumer upload dir for user attachments) when set |
| `harnesses/claude/hooks/phoenix-backend-developer-guard.sh` | PreToolUse — guards backend developer file scope |
| `harnesses/claude/hooks/phoenix-frontend-developer-guard.sh` | PreToolUse — guards frontend developer file scope |
| `harnesses/claude/hooks/static-site-ex-guard.sh` | PreToolUse — blocks .ex file writes in static site context |
| `harnesses/claude/hooks/track-subagent-edits.sh` | PreToolUse — tracks files edited per subagent for session log |
| `harnesses/claude/hooks/track-tool-failures.sh` | PostToolUseFailure — logs tool failures to global `~/.claude/tool-failures/<session>_<agent>.jsonl`; also appends `{ts,tool,error,agent}` to `codegen/logging/failures/<session>.jsonl` when `shared/enforcement/registry.yaml` sentinel present (codegen-repo only). Reader: `read_tool_failures` in hooks-lib.sh; surface: `make show-failures`. |
| `harnesses/claude/hooks/usage-rules-grep-guard.sh` | PreToolUse — enforces grep usage rules (no bare grep on files) |
| `harnesses/claude/hooks/llm-test-guard.sh` | PreToolUse — guards individual LLM test invocations |
| `harnesses/claude/hooks/claude-debug-bash-guard.sh` | PreToolUse — bash guards in claude-debug mode |
| `harnesses/claude/hooks/shape-remote-readonly.sh` | PreToolUse, shape role — closed read-only `ssh` grammar; denies BEFORE ssh runs on unclassified/mutating payload or bad host. Seam: `SHAPE_REMOTE_SSH_CONFIG`. |
| `harnesses/claude/hooks/lib/hooks-lib.sh` | Shared bash library: `session_log_from_transcript`, `pitch_from_transcript`, `read_tool_failures`, `read_gate_verdicts`, `guard_breadcrumb` (best-effort JSONL append to `codegen/logging/.guard-diagnostics/<sid>.jsonl`; fires before deny/block in cycle-spawn guards), `is_codegen_log_write`, transcript JSONL parsing, path helpers. Build-scoped filesystem fallback for transcript lag (see `context/hook-authoring-patterns.md` § Transcript Lag). |
| `harnesses/claude/hooks/lib/gate-select.sh` | Selects the gate from ONE source — the per-app `<project>/.claude/gate-config.sh`, sourced for the REQUIRED `GATE_COMMAND` plus the OPTIONAL `GATE_MODE` (`short`\|`long`) and `GATE_TIMEOUT` (seconds). Emits `gate=`, `mode=`, `timeout=` lines, or the fail-loud `__GATE_UNRESOLVED__` sentinel when no config file / no `GATE_COMMAND` — there is NO stack-guessing fallback, no default gate, and no per-cycle override from any role's output. Unset/empty mode/timeout → derived from the command string by `gate_mode_for`/`gate_timeout_for`, set → taken verbatim, malformed → `__GATE_UNRESOLVED__` (never a silent fall-back to the heuristic). All three are pre-cleared before the config is sourced, so a stale caller env var cannot masquerade as a declaration. Shelled by both interactive-session fallback hooks AND loop's `LoopGate.decide_gate`. |
| `harnesses/claude/hooks/_waiver.sh` (+ `.ts` twin) | Shared helper (not registered): `waived? <id>` true iff env `CODEGEN_WAIVED_GUARDS` (developer-only) + `building/<slug>.md`'s `waives:` frontmatter + registry `waivable: true` agree; else enforce. Records `ev:waiver`. Consumed by `prompt-budget-writer-only.sh` only; see `session-log.md` § A guard is waived only where a pitch declared it. |
| `harnesses/claude/hooks/lib/gate-result.sh` | Shared helper: `write_gate_result` + verdict truth table + witness extraction — full contract owned by `context/cycle-record.md`, not duplicated here. Shelled by both the interactive-session fallback AND the loop's `LoopGate.run_gate`. Lives HERE, not in `hooks-lib.sh` — source explicitly. Reader: `read_gate_verdicts` in hooks-lib.sh; surface: `make show-verdicts`. |
| `harnesses/claude/hooks/lib/cycle-state.sh` | `CYCLE_STATE_ORDER="GATED REVIEWED CURATED COMMITTED"` + helpers (`cycle_state_is_terminal`, `cycle_state_next`, `cycle_state_role`). Shelled by the loop's `advance_cycle_state_step/3` after each transition (GATED → REVIEWED → CURATED → COMMITTED). `CURATED → COMMITTED` resolves to no next agent — same as `GATED`/`COMMITTED` — because the commit step is the deterministic `codegen-commit` script, not a spawnable role. Unknown state: `is_terminal` → false, `next` → empty → fail-open. |
| `harnesses/claude/hooks/lib/wiring-check.js` | Static Phoenix handler-wiring verdict engine: every `phx-*` handler must have an element-driven side-effect test; FAIL blocks the gate. No browser, no server — pure string scan of `lib/**/*.heex` + `~H"""` sigils + `test/**/*_test.exs`. Emits `WIRING_VERDICT=PASS\|FAIL:<detail>\|INCONCLUSIVE:<reason>` |
| `harnesses/claude/hooks/lib/wiring-check_test.sh` | Verdict-logic + `node --check` parse guard for wiring-check.js; ≥14 fixture-driven cases (PASS, FAIL, INCONCLUSIVE, unresolvable-selector, ~H sigil, ancestor-id, text-selector, multi-handler partial-wired) |
| `harnesses/claude/hooks/lib/render-check.js` | Headless Chromium render verdict engine: DOM non-empty, styles applied, no JS errors. Parse guard: detects dup fn defs via `node --check`. Phoenix mode `--spawn <dir>` self-boots `mix phx.server` (real app, not an assumed-already-running port) — boot failure fail-closes to `FAIL:server-boot-failed`, not `INCONCLUSIVE`. `--port <N>` (assume-running probe) still emits `INCONCLUSIVE:server-unready`. |
| `harnesses/claude/hooks/lib/render-check_test.sh` | Regression guard: `node --check` on render-check.js + phoenix-server.js; tests SyntaxError paths for duplicate functions |
| `harnesses/claude/hooks/portable-launcher_test.sh` | Real launcher tests, both callers (`claude-shape/experiment`): CONTEXT_FLAGS/ROLE_SYSTEM_PROMPT append, drift-block, pitch resolution, Tier-0/Tier-1 loading via `pitch-context-selector.sh` (fail-open, citation priority, 6-row cap, missing-file error) |
| `harnesses/claude/hooks/build-launcher-wrapper_test.sh` | Hermetic wrapper tests for claude-build.sh: CODEGEN_DIR 3-branch resolution, --queue dispatch, basename resolution, cwd normalization. ALL terminal execs stubbed. Sibling: `loop-signal-bridge_test.sh` covers the queue signal-teardown path. |
| `harnesses/claude/hooks/prompt-content-parity_test.sh` | Verifies baked shape prompts preserve fixed sentinel strings: `ASK-GATE: product forks only`, `INTERACTION-AUDIT: compose-check siblings`, `Never treat N prose...`; non-sentinel edits to spine or shape bodies do not require sentinel sync |
| `harnesses/claude/hooks/role-boundary-parity_test.sh` | Drift guard for role boundary enforcement: extracts allowlist verb tokens from `registry.yaml` reviewer `match:` regex; asserts each appears in the corresponding rule file (`.md`). Tests both directions (registry-parity and prose-parity), substring-safety (codegen-log vs standalone git `log`), exit codes. |
| `harnesses/claude/hooks/run-tests.sh` | Auto-discovers `*_test.sh`; `HOOK_TEST_EXCLUDE` removes direct-target duplicates under `make test`, so each has one owner; standalone runs all. A NUL temp-file guard skips empty `xargs`; gate-pending's NUL loop leaves empty dirs empty on BSD/GNU. Its live gate-pending snapshot excludes ephemeral `codegen-invocation.*` wrapper sentinels but still checks durable files (`gate-result.json`, `gate-run.log`, `queue.lock`) for suite-caused mutation/removal. |

## Hook Event Types and Scripts

Event → script mapping from `harnesses/claude/claude-code-settings.json`:

| Event | Hook Scripts (key ones) | Purpose |
| - | - | - |
| `PreToolUse` | no-cat-pipe, no-python-json, no-git-stash, orchestrator-no-source-edit, orchestrator-no-ci, orchestrator-read-discipline, subagent-read-discipline, pre-commit-guard, dev-no-ci, developer-no-self-gate, reviewer-guard, reviewer-bash-allowlist (GENERATED), context-curator-guard, rule-edit-reach, context-index-parity, operator-subagent-allowlist, build-worker-cwd-guard, phoenix-backend-developer-guard, phoenix-frontend-developer-guard, static-site-ex-guard, session-log-writer-only, track-subagent-edits, usage-rules-grep-guard, llm-suite-guard, llm-test-guard, claude-debug-bash-guard | Discipline enforcement before tool runs |
| `PostToolUse` | (autovalidate inline script for `make llm-phoenix`) | Post-tool validation |
| `PostToolUseFailure` | track-tool-failures | Logs tool failures for diagnostics |
| `SubagentStop` | none registered | No SubagentStop hook remains — the last one, developer-no-self-gate-reset, was deleted as dead code: the loop runs roles as main sessions (no SubagentStop per-role) — loop covers gate exec (`LoopGate`), formatting (`run_format_step`), cycle-state advancement, env-var sample-consistency (`run_env_var_step` → `harnesses/claude/hooks/lib/env-var-sample-scan.sh`, diffs vs HEAD, flags ANY newly-added string-literal env-var read (bare/defaulted/`||`/`case`/`==`/`fetch_env!`) undeclared in BOTH sample files — documentation axis, not crash-ability; ambient OS/shell vars (`HOME`,`PATH`,`LC_*`) exempt via allowlist), curator factcheck + index-parity (pre-invoke seed + post-turn backstop, `run_curator_doc_check` → `context-factcheck-scan.sh` + `context-index-parity-scan.sh`; 3 claim classes: named-path, count-anchor, id-corruption), and the deterministic commit step (`run_commit_step` shells `codegen-commit`, no role invocation at all — see `context/loop.md`). Pre-loop equivalents deleted (covered above). |
| `Stop` | llm-pending-sweep, pitch-format-validator, build-queue-continuity, stop-resume, role-retrospective-before-stop | End-of-session guards (non-build modes: debug/shape/ops/experiment; role-retrospective-before-stop also fires under the loop) |
| `UserPromptSubmit` | (inline: `/orchestrate` session state capture) | Session routing for `/orchestrate` command |
| `SessionStart` | (inline: orchestrate session context restore) | Restores context after compact |
| `SessionEnd` | (inline: cleans up orchestrate session JSON) | Cleanup |
| `WorktreeCreate` | worktree-create-phoenix | Reads stdin `{name, cwd, session_id, hook_event_name}`; constructs `worktree_path=$cwd/.claude/worktrees/$name`, `branch=worktree-$name`, `base_ref=HEAD`; creates worktree, seeds Phoenix deps/_build, allocates port |
| `WorktreeRemove` | worktree-remove-phoenix | Reads stdin `.worktree_path`; derives name via `basename "$worktree_path"`; releases port allocation (observe-only) |

## context-curator-guard Write Surface

`harnesses/claude/hooks/context-curator-guard.sh` — PreToolUse hook restricting curator to: `context/**`, `codegen/rules/**` (symlink path only — hook receives the symlink path, NOT the resolved target), `codegen/logging/**`, and `PROJECT_CONTEXT.md` (§ Domain Context Files rows — index↔context parity). Fires only when `AGENT_TYPE == "context-curator"` and tool is `Edit|Write|MultiEdit`.

**DENIED**: Direct `shared/rules/` paths — only the `codegen/rules/` symlink path is allowed. Boundary cases also DENIED: `codegen/recipes/`, `codegen/rulesets/` (pattern anchors on `/rules(/|$)`).

Cross-reference: curator decision tree → `context/rules-roles.md` § Curator Write Surface; rule text → `shared/rules/roles/context-curator.md` § Write Surface.

## Index-Parity + Factcheck (writer's-turn placement)

`harnesses/claude/hooks/lib/context-index-parity-scan.sh` — working-tree scan (no hook I/O): a `context/*.md` add/delete without matching `PROJECT_CONTEXT.md` § Domain Context Files parity is a violation. Used by the turn-0 `run_orientation_preflight/4` preflight (all-curator-writable drift repairs via `context-curator`, else `InfraAbort` at $0 — `context/loop.md` § Turn-0 Sibling) AND the in-loop curator-stage scan (pre-invoke seed + post-turn backstop) — cannot be a per-edit gate (an ADD needs BOTH the file AND its row; whichever write lands first would deadlock a PreToolUse gate).

**Satisfy**: Append a row to `PROJECT_CONTEXT.md` § Domain Context Files table with the basename (e.g., `"deployment-topology"` for `context/deployment-topology.md`).

`harnesses/claude/hooks/context-factcheck-edit-gate.sh` — PreToolUse: denies a write to any orientation doc whose PROJECTED post-write content fails `context-factcheck-scan.sh` (temp mirror). Writer's own turn. **Doc-root split**: `FACTCHECK_DOC_ROOT` reads doc from mirror; path/count probes resolve against real `repo_root` — else every valid claim falsely denies. Both twins set both. **Named-path escapes** (three categories): (1) downstream-app paths need a placeholder segment `` `<app>/context/core.md` `` (out of grammar by `<`); (2) gitignored machine-local paths (e.g. `codegen/drain-nodes.yaml`) need nothing — claim-miss checked via `git check-ignore -q`, skipped on rc 0, violated otherwise; tracked paths never report as ignored. (3) env-var runtime paths — SCREAMING_SNAKE first segment (e.g. `` `PLATFORM_ROOT/PLATFORM_INFO.md` ``, all top-level repo dirs are lowercase) → skipped on claim-miss, no placeholder needed; an existing all-caps path still validates.

## Session Log Role-Event Detection

Cycle logs are append-only JSONL (one JSON object per line, `"ev"` discriminator field) — there is no markdown section structure to pattern-scan anymore. Hooks check session log state via `jq` role-event selectors against the log file:

| Check | Canonical `jq` form |
| - | - |
| role has run (any role) | `jq -e --arg r "<role>" 'select(.ev=="role" and .role==$r)' <file>` |
| loop-authored event (stack-agnostic) | `jq -e 'select(.ev=="files_to_touch" and .role=="loop")' <file>` |
| developer has run (any stack variant) | `jq -e 'select(.ev=="role" and (.role \| startswith("developer-")))' <file>` |
| reviewer has run (any stack variant) | `jq -e 'select(.ev=="role" and (.role \| startswith("reviewer-")))' <file>` |
| concatenated role body text | `jq -r --arg r "<role>" 'select(.ev=="role" and .role==$r)\|.body' <file>` |

`loop` and `context-curator` are stack-agnostic — the role string is always the literal value, no stack suffix. Only `developer-*` and `reviewer-*` carry a stack suffix, which is why those two are matched via `startswith(...)` rather than an exact string; the full accepted vocabulary is `loop | developer-* | reviewer-* | context-curator` (`codegen-log`'s own role check). There is no `committer` role — the commit step is the deterministic `codegen-commit` script, authored as `loop` in the `{"ev":"committed",...}` event.

All `jq -e` reads exit 0 = at least one match, exit 1 = none. Wrap in `2>/dev/null` on read paths (swallow malformed-line noise, fail-open) except where a hard block requires certainty. Full event schema and reader forms: session-log rules § Event Schema.

## Retrospective Placement Rule (role-retrospective-before-stop)

`subagent-retrospective-guard.sh` (SubagentStop) and the loop's post-role warm-resume step were both dead/unwinnable and deleted (mismatched prompt/validator contract).

Replaced by **`role-retrospective-before-stop`**, a `Stop`-event hook gating `developer-*|reviewer-*` (curator exempt; the deterministic commit step is a script, not a role, so it is not in scope for this hook at all). It BLOCKS: pushes the role back into its OWN warm session naming the exact `codegen-log` command. Checks per role: non-empty `ev:role` body + EITHER `ev:learned` OR `ev:no_learning`. Substance enforced at the writer — `codegen-log` refuses placeholder/compliance-echo payloads (exit 2). Bounded at 3 blocks/session, then falls through — never fails the build. `section <role> --learned "<text>"` is the one-call path; `append <role> --no-learning "<text>"` is the legal empty-turn exit (session-log rules § Ownership).

### Slug Extraction Patterns

When extracting a slug from a cycle log filename, use a **fixed-width regex anchored on timestamp and suffix**, not a pattern that splits on `_`. This handles slugs containing underscores without ambiguity.

**Canonical pattern** (matches the slug-extraction block in `codegen-log`'s `init` subcommand):

```bash
slug=$(basename "$log" | sed -E 's/^[0-9]{8}_[0-9]{6}_(.+)_cycle\.jsonl$/\1/')
[ -z "$slug" ] && exit 0  # no match → skip
```

**Why fixed-width**: Splitting on the last `_` would incorrectly fragment a slug containing an underscore. Prefix/suffix anchoring on the 8-digit date and 6-digit time is unambiguous.

### Cycle Log Filename Regex — Single-Source Contract

**Canonical regex** (authoritative source: `shared/rules/_core/session-log.md` § File Naming):

```
[0-9]{8}_[0-9]{6}_[a-z0-9_-]+_cycle\.jsonl$
```

**Consumed by** (MUST be kept in sync — parity-tested):
- `hooks-lib.sh`: `SESSION_LOG_NAME_RE` variable (shared by all guards that need to validate log filenames)
- Bash guard: `reviewer-guard.sh` (references the variable)
- `registry.yaml`: `match:` line for the above guard (hardcoded; parity-tested in `make test`)
- `session-log.md` § File Naming (canonical prose)

When the regex changes, update `hooks-lib.sh` first, then regenerate guards via `make install`, then verify all sites match via parity test.

## Key Paths

```
harnesses/claude/hooks/
  *.sh                     ← hook scripts (installed to ~/.claude/hooks/)
  *_test.sh                ← paired bash tests
  run-tests.sh             ← test runner
  lib/
    hooks-lib.sh           ← shared library
    gate-select.sh
    hooks-lib_test.sh
    gate-select_test.sh
templates/generator/hook_registrations.py  ← generates settings.json entries
```

## Integration Points

- **core**: `hook_registrations.py` reads hooks source dir; `install.sh` copies hooks to `~/.claude/hooks/`
- **harnesses**: `claude-code-settings.json` declares hook event → script mappings; generated version installed at `~/.claude/settings.json`; see `context/harnesses.md` for harness install contract details
- **rules**: hooks enforce rules at runtime (e.g. `no-python-json.sh` → `bash-discipline.md` rule). For builds, gate verdict _generation_ and _reaction_ are both owned by the Elixir loop (`test_harness/lib/codegen_test_harness/loop_gate.ex`, `orchestration_loop.ex`), not by SubagentStop hooks.
- **test-harness**: hook tests (`*_test.sh`) are bash scripts; `run-tests.sh` runs them separately from ExUnit suite

## Test Suite Behavior — Combined make test vs Hermetic-Only

`make test` core-gates its old isolation tail. At validated logical cores ≥ `TAIL_OVERLAP_MIN_CORES` (default 6), `hooks`, `test-hermetic`, and `rule-render-freshness` join phase 1; below it, the serial tail remains. Invalid inputs exit 1 before branch selection. Hook dedup keeps exact-once ownership. Signal/postflight fixtures use readiness events, bounded polls, and owned PID/PGID cleanup, so public `harness-parity` safely runs its full population in one parallel pool. A red gate is authoritative.

**Static sentinel co-location tests**: a same-line sentinel assert (e.g. `SETTINGS_JSON=.*API_FORCE_IDLE_TIMEOUT`) breaks under variable-indirection refactors. Fix: assert co-location at the variable level (separate assignment-line + reference-line patterns) — robust to indirection, still captures the invariant.

**Hermetic CI tests vs hooks**: `context-doc-provenance_test.sh` scans docs/rules for rotting line-citations — not a hook/registry entry, absent from `settings.json`. Auto-discovered via `run-tests.sh` footer (`N passed, N failed`). Full-tree context-index parity IS a `make test` gate — `make context-index-parity`, run against this repo's own docs, not only against fixtures. It was excluded on the theory that the build-time curator scan (`context/loop.md` § Curator-Doc Check turn-0 preflight + in-loop scan) was the only consumer; the result was that index drift blocked every build for twelve days while `make ci` stayed green. A gate that can block a build must be visible to CI. The gate has two legs: `context_index_sync.py --check` (the index's trigger column is GENERATED from each `context/*.md` § Trigger Keywords — fix with `make context-index-sync`, never by hand) and `context-index-parity-scan.sh` (coverage, phantom rows, missing Trigger Keywords sections, non-`.md` clutter). Replaces deleted `context-index-coverage_test.sh`. The hook runner's live `codegen/gate-pending/` backstop intentionally filters `codegen-invocation.*` because those are wrapper lifecycle sentinels, not durable gate evidence.

## See Also

For matrix of which hooks gate which launcher modes (build vs debug/shape/refactor vs ops), see `context/launcher-hook-matrix.md`.

For hook authoring patterns (how to write/test a hook, output protocol, gate verdict flow, hooks-lib usage, registration mechanics) → `context/hook-authoring-patterns.md`.

For the loop's own gate mechanism, engine, and decider map (the build path) → `context/loop.md` (single-cycle) and `context/loop-queue-drain.md` (multi-pitch queue). For the gate verdict truth table and cycle-log schema → `context/cycle-record.md`. `context/test-harness.md` owns the ExUnit test SUITE that exercises the loop, not the loop itself.

## Enforce-Registry-Parity — Compiler-Generated Files & Gate Ordering

`enforce-registry-parity` compares **only** `kind: denial` compiler-generated files against output from `enforcement_compiler.py`. (Claude's reviewer Bash allowlist is `reviewer-bash-allowlist.sh`, a separate `kind: registration` entry). **Hand-authored `kind: registration` hooks are NOT checked by this gate** — registry edits to registration entries flow through `hook-header-parity` (HOOK-MANIFEST header) and `hook-parity` (settings.json) instead. The hook test (`enforce-registry-parity` make target) diffs compiler output with HEAD:

- **Compiler format**: Single-line, compact (no multi-line conditionals)
- **Prettier format**: Multi-line, human-readable (applied at commit time)

If a file is committed with prettier multi-line formatting, the committed version will drift from the compiler's compact single-line output → parity fails.

**Critical gate ordering**: Edit registry → `make install` FIRST (regenerates committed generated files) → `make test`. Reversed order causes `enforce-registry-parity` drift failure. Never run prettier on compiler-generated files.

**Multi-value `role:` compiler case-arm join**: compiler joins `role: "a|b"` with `" | "` (space-padded, not bare `|`) in generated `case "$AGENT_TYPE" in a | b) ;;` guards — `hook_registrations.py`'s parity checker requires each token to match `<token>)` or `<token> |` literally; a bare `a|b)` join fails `make hook-parity`. Fix is compiler-side (POSIX `case` accepts space around `|`).

## Quote-Aware Matching — `strip_quoted`/`ignore_quoted`

Command-scanning guards grepping raw `$COMMAND` over-fire on tokens inside quoted spans (remote payloads `ssh host "cat f|head"`, quoted args `grep -n 'git stash' f`) that aren't real local invocations. `strip_quoted`/`stripQuoted` (`hooks-lib.sh`/`hook-helpers.ts`, beside `is_codegen_log_write`) strips quoted spans first — fail-closed: unquoted real invocation still matches/denies, quoted form bypasses.

Compiler `{match_subject}` placeholder + registry `ignore_quoted: true` (no-cat-pipe, no-git-stash) selects strip-wrapped subject vs bare literal (default, byte-identical). `pre-commit-guard` (hand-authored twin) computes unquoted residue post-carve-out for all git-verb sites.

`strip_git_global_opts` treats its command string as data: its whitespace token walk scopes `set -f` and restores the caller's prior noglob state. Literal `*`/`?` arguments therefore cannot pathname-expand against a large caller cwd before `pre-commit-guard` reaches its verb checks.

Excluded: `no-python-json` (stripping disables its intrinsically-quoted `-c "<json>"` form).

**`expand_command_indirection`/`expandCommandIndirection`** (beside `command_invokes`): raw `$COMMAND` guards miss a verb hidden in a REFERENCED SCRIPT body (`bash /tmp/x.sh`, written in a prior call). Per segment, word ∈ `bash|sh|zsh|source|.` + first non-flag argv token resolving to a readable regular file → body appended on its own line. Additive-only (original always the prefix), depth-1, fails open. Applied unconditionally in `pre-commit-guard`; opt-in via `resolve_indirection: true` for compiled guards (composes with `ignore_quoted`) — currently `no-git-stash` only. `no-cat-pipe`/`no-python-json` opt out (false-positive risk). **Note**: `bash -n <path>` against a file whose body legitimately contains `git add`/`git commit` (e.g. `codegen-commit` itself) triggers `pre-commit-guard` via this indirection-resolution path — a probe on that file's syntax must go through a non-`bash -n`-literal route (e.g. `python3 -c "subprocess.run(['bash','-n',...])"`) to avoid the false trip.

## Main-Agent-Scoped Guards (Registration-Based)

Guards scoped to the main-agent session (empty `AGENT_TYPE`/`AGENT_ID`) use `kind: registration` entries — not the `generated: true` denial pipeline. The main-agent session lacks a named role; `role: "*"` would double-cover reviewer allowlists.

**Pattern**: (1) `kind: registration` entry in `registry.yaml` with `role: "*"`, `harnesses: all`; (2) hand-authored `.sh` file with pre-check on `^codegen/logging/` to avoid wrongly denying non-logging writes; (3) `_test.sh` with ≥16 cases; (4) `make install` injects `HOOK-MANIFEST` header + registers in `settings.json`.

**orchestrator-read-discipline hand-authorship**: The `.sh` + `.ts` bodies of `orchestrator-read-discipline` are fully hand-authored (not generated) — the `kind: registration` flag only SKIPS body generation; the `# HOOK-MANIFEST:` header is auto-injected but the body strings are edited directly in both files. When fixing deny-message text, ensure ALL four deny strings are updated in lockstep: the `.sh` top-comment block (deny-message description near `# rationale:`), the `.sh` Read-deny arm (inside the `Read` handler), the `.ts` Bash-deny arm, and the `.ts` Read-deny arm. Omitting any drift-branch causes misdirection in one harness and violates Rule J (parallel hand-authored twins must stay synchronized).

**Path normalization**: Strip leading `./` explicitly (`rel="${rel#./}"`) so both a session-log file and its `./`-prefixed form match the allowlist.

## Shell Case Branching Pattern

Specific arms BEFORE wildcards in shell `case` (first-match wins). `LoopGate.decide_gate/1` follows the same discipline in Elixir.

## Git Status Porcelain Parsing

`awk '{print $2}'` on renamed files (`R  old -> new`) truncates the arrow+target. Use `sed 's/^[^ ]* //'` — strips status code + one space, preserves full paths incl. renames/spaces. Used by `clean-tree-before-ship.sh`.

## Session-Log Writing (codegen-log Sole-Writer Model)

`codegen-log` is the SOLE writer of cycle logs (append-only JSONL). Raw Edit/Write/Bash writes denied by `session-log-writer-only` hook.

**Core ops**:
- `init --slug <slug> [--stamp <ts>]` — create log; binds by RUN IDENTITY (path from `--stamp`, or `date -u` when omitted), never a slug-only glob, so a retry mints its own log; loop-only, refuses (exit 2, `.active` untouched) when `CODEGEN_LOG_PATH` set — role MUST NOT `init` inside a cycle.
- `section <role> --slug <slug>` — append `{"ev":"role","role":<role>,"body":<prose>}`.
- `append <role> --slug <slug>` — append `{"ev":"role",...}` event.
- `append <role> --learned "<text>" --slug <slug>` — append `{"ev":"learned",...}`.
- `append <role> --died interrupted|aborted --slug <slug>` — append `{"ev":"died",...}`.
- `append <role> --verdict clear|failed|inconclusive --slug <slug>` — append `{"ev":"gate",...}`.
- `append <role> --files-to-touch|--files-modified @- --slug <slug>` — typed read-discipline markers (JSON array of strings on stdin, shape-validated at write). The **loop** authors `files_to_touch` (`"role":"loop"`), sourced deterministically from the pitch's `scope:` frontmatter field — it is what grants the developer its `context/*.md` Reads; `developer-*` authors `files_modified`, which grants the reviewer's. `subagent-read-discipline.sh` reads each field from the AUTHOR's event, never the calling role's own and never a prose fallback, so a caller-authored self-read cannot self-authorize a Read. (There is no `plan` or `plan_gate` event kind: the pitch body replaces the plan, and gate command/mode/timeout come from `<project>/.claude/gate-config.sh`.)
- `verdict --gate <cmd> --mode <mode> --result "<text>" [--detail "<text>"] --slug <slug>` — the loop's dev-gate step verdict writer. `--detail`: located witness on FAILED, else a named sentinel (never `""`); see `witness-discipline.md`.
- `relocate --new-slug <slug>` — rename + update `.active`.
- `exit --status <n> [--signal <n>] [--stderr-tail "<text>"]` — append `{"ev":"exit",...}` (no role). Written by `dispatch.sh` after `wait`ing the loop child; no resolvable log → one stderr note, exit 0, nothing written.
- `committed --role <role> --sha <sha> --subject "<text>"` — append `{"ev":"committed",...}`. Always loop-authored (`--role loop`) — the commit step is the deterministic `codegen-commit` script, never a spawned role.

**Resolution**: `CODEGEN_LOG_PATH` env > `--slug` > `.active` sentinel > mtime — same order for the CLI AND both guard resolvers (`session_log_from_transcript`, `getActiveStepLog`), so a rival same-process `init` cannot hijack what a guard grades. Full contract: `shared/rules/_core/session-log.md` § Ownership.

## Test Assertion Discrimination Patterns

**Presence-only vs co-location asserts**: Presence-only `assert_file_contains` is weak for boolean env-injection tests (key leaking to BOTH branches passes silently). Use co-location assertions: `grep -c 'SETTINGS_JSON=.*API_FORCE_IDLE_TIMEOUT.*NONINTERACTIVE'` to verify assignment co-locates with branch test.

## Pitfalls

- **Phoenix gates**: wiring-check → render-check → runtime. [local] **T17 watchdog signal**: exit 0 + slug-ready + NOT-shipped (timeout-only); not messages (racy).
- **Stop-hook block timeout ceiling**: ~300–350s honored, NOT the 360s registration timeout; ≥350s silently drops (no error/retry). Verified N=300 ✓, N=350/400 no block.

## Testing & Verdict Patterns

- **Bash isolation**: `sed -n '/<fn>/,/<close>/p' | eval` avoids argparse `exit` when testing helpers.
- **Timestamps**: `YYYYMMDD_HHMMSS` sorts lexically ≡ chronologically. Use `[ "$ts1" \< "$ts2" ]` for portable compare.
- **Bash patterns**: `#` and `[]` are glob-special in `${var%%pattern}` expansions. Hook simulation may fail; test literal code.
- **Gate verdict**: the runtime-written gate-result JSON's `.verdict` field is authoritative, never session-log prose. Manual re-runs don't update JSON. The build now fails closed on `codegen-build` if the post-dispatch verdict is absent or not `clear`.

## Bash Hook Test Debugging — Silent Crashes & Early Exits

ALL blocking tests fail while non-blocking pass → suspect an early fatal crash (unbound var under `set -u`, syntax error) — hook exits non-zero before `block()`, verdict never emitted, looks like "allow". Diagnostic: `bash -x <hook>.sh 2>&1` — find where execution stops; fix by hoisting assignment or `${var:-}` guard.

## Trigger Keywords

PreToolUse, SubagentStop, Stop hook, Elixir orchestration loop, LoopGate, hook test, run-tests.sh, empty xargs discovery, gate-pending snapshot, core-gated hook overlap, gate verdict, hook registration, orchestrator hook bypass, resolve_role, ops bypass, per-role gate, AGENT_TYPE gate, gate-result.json verdict, codegen-log, session-log writer, marker flags, .active sentinel, positional-role, slug-class regex, session-log contract, codegen-commit, deterministic commit step
