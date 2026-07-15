# Hooks Domain — Hook System (Bash + Tests)

The hooks domain covers all Claude Code hook scripts, their shared library, registration mechanism, and bash test suite. Hooks fire on `PreToolUse`, `SubagentStop`, and `Stop` lifecycle events — these are the events codegen currently registers; Claude Code supports a larger event catalog (see § Hook Event Types and Scripts below). Each hook has a paired `_test.sh` file; `run-tests.sh` runs the full suite.

**Builds are driven unconditionally by the deterministic Elixir orchestration loop** (`mix codegen.loop`, invoked unconditionally by `dispatch.sh` for every build) — there is no interactive self-orchestrating build session. Because the loop invokes each role as a separate main-agent `codegen-call` (`claude -p --print`), there is NO `SubagentStop` event under the loop — SubagentStop-matched hooks fire only in non-build modes (debug/shape/ops/experiment) that still spawn subagents outside the loop. PreToolUse hooks fire normally in every per-role session regardless of mode.

Hook registration: **Two pipelines** (`enforcement_compiler.py` for `kind: denial` full-file generation; `hook_registrations.py` for `kind: registration` header-only injection + settings.json generation). Counts (verify): `grep -c 'kind: denial' shared/enforcement/registry.yaml` = 2, `grep -c 'kind: registration'` = 47. Full mechanics (compiler ownership boundary, header/body split, workflow order) → `context/hook-authoring-patterns.md` § Hand-Authored Hook Script Structure & Registration / § Hook Registration Mechanics (this file does not duplicate that detail).

**Deferred (not-yet-migrated):** `subagent-read-discipline.sh` keeps a hand-authored header until a follow-up wave. Prior `role: unset` outliers (`context-index-parity.sh`, `context-file-size-gate.sh`, `context-factcheck-guard.sh`) were deleted — moved to `context-factcheck-edit-gate.sh` + in-loop `run_curator_doc_check`. Deferred entries live in `registry.yaml` as a commented-out stanza in TWO places (registration section + header-block comment) — keep synced.

**`committer-bash-allowlist` pattern (generated from registry)**: Regex pattern in `shared/enforcement/registry.yaml` defines which Bash commands committer may invoke. Current pattern permits: optional `(cd\s+\S+\s+&&\s+)?` prefix (cross-repo execution) + allowlisted commands (git subcommands optionally preceded by `-C <path>`, or utilities like `echo`, `wc`, `ls`, `true`). The pattern supports both `cd /path && git commit` (shell prefix) AND `git -C /path commit` (inline flag), while DENYING non-allowlisted commands after a `cd` prefix (no shell-escape loophole). Inner alternation on `git\s+` includes an optional `(-C\s+\S+\s+)?` group to permit the inline flag form. This is a generated (read-only) file; the source is `registry.yaml`. See `shared/rules/_core/bash-discipline.md` § Renderer-Neutral Regex Tokens for token safety when defining such patterns.

**codegen-log write bypass (shared helper)**: 13 command-scanning PreToolUse Bash guards (`developer-no-self-gate.sh`, `dev-no-ci.sh`, `committer-single-commit-per-cycle.sh`, `committer-no-revert-prior-commit.sh`, `committer-no-head-move-reset.sh`, `committer-no-trailer-guard.sh`, `committer-single-line-guard.sh`, `committer-subject-length.sh`, `committer-gate-verdict-clear.sh`, `orchestrator-no-ci.sh`, `no-git-stash.sh`, `no-cat-pipe.sh`, `developer-static-no-manual-build.sh`) each call a shared `is_codegen_log_write()` helper (`hooks-lib.sh`) / `isCodegenLogWrite()` (Pi `hook-helpers.ts`) BEFORE any phrase grep or counter increment. A `codegen-log` invocation is always a session-log WRITE, never the gated action its heredoc body narrates (e.g. a log entry saying "ran make ci" must not itself be denied/counted as `make ci`). Mirrors the bypass already present in `session-log-writer-only.sh`/`.ts` and `pre-commit-guard.sh`/`planner-guard.sh`.

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
| `harnesses/claude/hooks/pre-commit-guard.sh` | PreToolUse — blocks direct `git commit` outside committer role; early codegen-log carve-out (mirrors session-log-writer-only's own pattern) exits allow BEFORE the git-verb scans when the command invokes codegen-log, so role-authored prose piped into a session-log section body is never denied by containing a git-verb token — bare history-mutating git commands remain denied |
| `harnesses/claude/hooks/dev-no-ci.sh` | PreToolUse — blocks developer from running CI commands |
| `harnesses/claude/hooks/developer-no-self-gate.sh` | PreToolUse — blocks developer gate invocation. Loop-mode sig file (3rd line) now also stores `CODEGEN_RESUME_ATTEMPT`; a new resume token vs. last-seen is treated as a fresh first-run (not a same-tree spin) — see "Warm-resume on transient retry" in `context/test-harness.md`. |
| `harnesses/claude/hooks/planner-guard.sh` | PreToolUse — enforces planner constraints (no writes, no bash exec); an early codegen-log carve-out (top of the Bash block, mirrors session-log-writer-only's own pattern) exits allow BEFORE the scans below when the command invokes codegen-log, so the plan's session-log section body (piped prose) is never denied by containing a gate token, git verb, redirect char, or `../` sequence; blocks (non-codegen-log commands): (1) Bash redirects to `codegen/logging/*.jsonl` including shell heredocs, `>>` appends, and brace-group redirect forms (all defeat transcript-based path detection); requires exact `codegen/logging/` or `/tmp/` path in redirect target (no `./codegen/logging/` prefix); (2) Read on implementer rule files (`developer.md`, `testing-liveview.md`, `testing.md`, `reviewer.md`, `committer.md`) to prevent token waste and over-specification; (3) `rm`/`rmdir` outside `/tmp/`; (4) `git` state-modify and state-inspection commands. **Implication**: session-log section body writes route through `codegen-log section --body @-` (piped), NOT bash redirect patterns of ANY form; edits to rule files must be planned blind (verbatim content + text anchors supplied to developer subagent). **Planning rule edits blind**: planner cannot Read rule files — use Grep tool to locate anchors, supply verbatim in pitch; developer uses those anchors with Edit tool. |
| `harnesses/claude/hooks/reviewer-guard.sh` | PreToolUse — reviewer constraint enforcement (Write/Edit/MultiEdit/Monitor deny; Bash no longer gated here — see reviewer-bash-allowlist.sh) |
| `harnesses/claude/hooks/reviewer-bash-allowlist.sh` | PreToolUse — reviewer Bash allowlist (GENERATED): default-deny; permits only `codegen-log` invocations (any position — typically piped, e.g. `printf '%s' "$body" \| codegen-log section --body @-`) plus safe read-only utilities (`git diff/status/log/show`, `echo`, `wc`, `cat`, `ls`, `true`, `:`). No history-mutating git verbs. Fills the Bash gap left when reviewer-guard.sh's Bash hard-deny arm was removed, so reviewers can write their session-log section via codegen-log. **Sandbox constraint**: The allowlist blocks direct invocation of `make`, `python3`, and `grep` — reviewers cannot execute the full `make test` gate directly. Gate-status verification falls back to `git log`/`git diff --stat` cross-checks: verify claimed-unrelated test files are untouched by the current diff and their last-touch commit predates the cycle, rather than re-running the gate. |
| `harnesses/claude/hooks/context-curator-guard.sh` | PreToolUse — guards context file edits to curator role only |
| `harnesses/claude/hooks/curator-context-size-gate.sh` | PreToolUse — denies curator Edit/Write to `context/*.md` when the result would exceed the 40960-byte cap; hard gate (not a warning) |
| `harnesses/claude/hooks/context-factcheck-edit-gate.sh` | PreToolUse (Edit\|Write\|MultiEdit, role: `*`) — denies ANY role's write to an orientation doc on a projected-content factcheck violation; superseded `context-factcheck-curator-stop.sh` + `context-factcheck-guard.sh`; full detail below in this same section |
| `harnesses/claude/hooks/operator-subagent-allowlist.sh` | PreToolUse — enforces agent delegation allowlist (role ∈ {debug, shape, ops}); gates slash commands that spawn subagents |
| `harnesses/claude/hooks/build-agent-app-confinement.sh` | PreToolUse — denies Write/Edit/MultiEdit outside CODEGEN_BUILD_CWD; role-agnostic; /tmp escape hatch; canonicalizes macOS /var↔/private/var; fills orchestrator-no-source-edit.sh subagent gap |
| `harnesses/claude/hooks/build-worker-cwd-guard.sh` | PreToolUse — guards build worker cwd discipline; whitelist honors optional `OCG_PHOENIX_SEED_DIR` and `OCG_USER_FILES_DIR` (consumer upload dir for user attachments) when set |
| `harnesses/claude/hooks/committer-bash-allowlist.sh` | PreToolUse — committer Bash allowlist: only git + safe shell utilities allowed (default-deny; GENERATED) |
| `harnesses/claude/hooks/committer-write-allowlist.sh` | PreToolUse — committer Write/Edit allowlist: only canonical session logs (GENERATED) |
| `harnesses/claude/hooks/committer-no-trailer-guard.sh` | PreToolUse — blocks commit trailers (Co-authored-by, etc.) |
| `harnesses/claude/hooks/committer-single-commit-per-cycle.sh` | PreToolUse — denies second non-amend git commit per build cycle (escape hatch: COMMITTER_ALLOW_MULTI=1) |
| `harnesses/claude/hooks/committer-gate-verdict-clear.sh` | PreToolUse — denies `git commit` from the committer agent unless `codegen/gate-pending/gate-result.json` exists and its `.verdict` field is `clear`; enforces the committer's mandatory verdict-read rule structurally |
| `harnesses/claude/hooks/committer-no-head-move-reset.sh` | PreToolUse — denies a HEAD-moving `git reset` (targeted commit-ish, or `--soft`/`--hard`/`--keep`/`--merge`) from committer; allows bare `git reset`, `git reset HEAD`, `git reset -- <path>` (escape hatch: COMMITTER_ALLOW_MULTI=1) |
| `harnesses/claude/hooks/committer-single-line-guard.sh` | PreToolUse — enforces single-line commit subject |
| `harnesses/claude/hooks/committer-subject-length.sh` | PreToolUse — enforces commit subject line length limit |
| `harnesses/claude/hooks/phoenix-backend-developer-guard.sh` | PreToolUse — guards backend developer file scope |
| `harnesses/claude/hooks/phoenix-frontend-developer-guard.sh` | PreToolUse — guards frontend developer file scope |
| `harnesses/claude/hooks/static-site-ex-guard.sh` | PreToolUse — blocks .ex file writes in static site context |
| `harnesses/claude/hooks/developer-no-self-gate-reset.sh` | SubagentStop (non-build modes only) — blocks developer from resetting its own gate |
| `harnesses/claude/hooks/track-subagent-edits.sh` | PreToolUse — tracks files edited per subagent for session log |
| `harnesses/claude/hooks/track-tool-failures.sh` | PostToolUseFailure — logs tool failures to global `~/.claude/tool-failures/<session>_<agent>.jsonl`; also appends `{ts,tool,error,agent}` to `codegen/logging/failures/<session>.jsonl` when `shared/enforcement/registry.yaml` sentinel present (codegen-repo only). Reader: `read_tool_failures` in hooks-lib.sh; surface: `make show-failures`. |
| `harnesses/claude/hooks/usage-rules-grep-guard.sh` | PreToolUse — enforces grep usage rules (no bare grep on files) |
| `harnesses/claude/hooks/llm-test-guard.sh` | PreToolUse — guards individual LLM test invocations |
| `harnesses/claude/hooks/claude-debug-bash-guard.sh` | PreToolUse — bash guards in claude-debug mode |
| `harnesses/claude/hooks/lib/hooks-lib.sh` | Shared bash library: `session_log_from_transcript`, `pitch_from_transcript`, `read_tool_failures`, `read_gate_verdicts`, `guard_breadcrumb` (best-effort JSONL append to `codegen/logging/.guard-diagnostics/<sid>.jsonl`; fires before deny/block in cycle-spawn guards), `is_codegen_log_write`, transcript JSONL parsing, path helpers. Build-scoped filesystem fallback for transcript lag (see `context/hook-authoring-patterns.md` § Transcript Lag). |
| `harnesses/claude/hooks/lib/gate-select.sh` | Selects gate from: (1) planner `**Gate**:` JSONL block (Tier-1 win), or (2) per-app `.claude/gate-config.sh` `GATE_COMMAND` env var (Tier-2 fallback). Emits `gate=`, `mode=`, `timeout=` lines, or fail-loud `__GATE_UNRESOLVED__` sentinel. Shelled by both interactive-session fallback hooks AND loop's `LoopGate.decide_gate`. |
| `harnesses/claude/hooks/lib/gate-result.sh` | Shared helper: `write_gate_result` writes the ephemeral runtime gate-result JSON into `codegen/gate-pending/` (not a committed repo file — regenerated per gate run); also appends the canonical record to `codegen/logging/gate-verdicts.jsonl` when sentinel present. `gate_result_verdict` reads `.verdict` (returns "" if absent). `write_gate_result` also supports a `witness` field (file:line + verbatim cause for FAILED gates) via `extract_witness <log_path>` — fall-open-empty contract — and a `graded_tree_sha` field (real git tree object binding the verdict to the exact content it graded, distinct from `base_sha` which only pins HEAD); `gate_result_graded_tree_sha` reads it back. Shelled by both the interactive-session fallback AND the loop's `LoopGate.run_gate`. **Note**: lives HERE, not in `harnesses/claude/hooks/lib/hooks-lib.sh` — source explicitly. Reader: `read_gate_verdicts` in hooks-lib.sh; surface: `make show-verdicts`. |
| `harnesses/claude/hooks/lib/cycle-state.sh` | `CYCLE_STATE_ORDER="GATED REVIEWED CURATED COMMITTED"` + helpers (`cycle_state_is_terminal`, `cycle_state_next`, `cycle_state_role`). Shelled by the loop's `advance_cycle_state_step/3` after each transition (GATED → REVIEWED → CURATED → COMMITTED). Unknown state: `is_terminal` → false, `next` → empty → fail-open. |
| `harnesses/claude/hooks/lib/wiring-check.js` | Static Phoenix handler-wiring verdict engine: every `phx-*` handler must have an element-driven side-effect test; FAIL blocks the gate. No browser, no server — pure string scan of `lib/**/*.heex` + `~H"""` sigils + `test/**/*_test.exs`. Emits `WIRING_VERDICT=PASS\|FAIL:<detail>\|INCONCLUSIVE:<reason>` |
| `harnesses/claude/hooks/lib/wiring-check_test.sh` | Verdict-logic + `node --check` parse guard for wiring-check.js; ≥14 fixture-driven cases (PASS, FAIL, INCONCLUSIVE, unresolvable-selector, ~H sigil, ancestor-id, text-selector, multi-handler partial-wired) |
| `harnesses/claude/hooks/lib/render-check.js` | Headless Chromium render verdict engine: DOM non-empty, styles applied, no JS errors. Parse guard: detects dup fn defs via `node --check`. Phoenix mode `--spawn <dir>` self-boots `mix phx.server` (real app, not an assumed-already-running port) — boot failure fail-closes to `FAIL:server-boot-failed`, not `INCONCLUSIVE`. `--port <N>` (assume-running probe) still emits `INCONCLUSIVE:server-unready`. |
| `harnesses/claude/hooks/lib/render-check_test.sh` | Regression guard: `node --check` on render-check.js + phoenix-server.js; tests SyntaxError paths for duplicate functions |
| `harnesses/claude/hooks/portable-launcher_test.sh` | Real launcher invocation tests: tests CONTEXT_FLAGS/ROLE_SYSTEM_PROMPT append logic, SCRIPT_DIR/CODEGEN_DIR drift-block, pitch resolution, Tier-0/Tier-1 context loading (always-load, fail-open, pitch-matched, dedup, 6-row cap) |
| `harnesses/claude/hooks/build-launcher-wrapper_test.sh` | Hermetic wrapper tests for claude-build.sh + pi-build.sh: CODEGEN_DIR 3-branch resolution, --queue dispatch (mix codegen.loop.queue), basename resolution, cwd normalization. ALL terminal execs stubbed (zero real LLM builds). 14 matrix cases × 2 launchers = 118 assertions. |
| `harnesses/claude/hooks/prompt-content-parity_test.sh` | Verifies baked shape prompts preserve fixed sentinel strings: `ASK-GATE: product forks only`, `INTERACTION-AUDIT: compose-check siblings`, `Never treat N prose...`; non-sentinel edits to spine or shape bodies do not require sentinel sync |
| `harnesses/claude/hooks/role-boundary-parity_test.sh` | Drift guard for role boundary enforcement: extracts allowlist verb tokens from `registry.yaml` committer/reviewer `match:` regex; asserts each appears in the corresponding rule file (`.md`). Tests both directions (registry-parity and prose-parity), substring-safety (codegen-log vs standalone git `log`), exit codes. 14 assertions: live + fixture ±drift cases. |
| `harnesses/claude/hooks/run-tests.sh` | Auto-discovers and runs all `*_test.sh` hook tests via a `find "$HOOKS_DIR" -name '*_test.sh'` call near the top of the script. Combined with manifest exemption (`--exclude-pattern=_test.sh` in hook_registrations.py), new CI-lint guards in `harnesses/claude/hooks/` need ZERO Makefile wiring or registry entries — file presence + exec bit is sufficient for auto-discovery. Test can be hand-authored (no HOOK-MANIFEST header required). |

## Hook Event Types and Scripts

Event → script mapping from `harnesses/claude/claude-code-settings.json`:

| Event | Hook Scripts (key ones) | Purpose |
| - | - | - |
| `PreToolUse` | no-cat-pipe, no-python-json, no-git-stash, orchestrator-no-source-edit, orchestrator-no-ci, orchestrator-read-discipline, subagent-read-discipline, pre-commit-guard, dev-no-ci, developer-no-self-gate, planner-guard, reviewer-guard, reviewer-bash-allowlist (GENERATED), context-curator-guard, context-index-parity, operator-subagent-allowlist, build-worker-cwd-guard, committer-bash-allowlist (GENERATED), committer-write-allowlist (GENERATED), committer-no-trailer-guard, committer-single-line-guard, committer-subject-length, committer-gate-verdict-clear, phoenix-backend-developer-guard, phoenix-frontend-developer-guard, static-site-ex-guard, session-log-writer-only, track-subagent-edits, usage-rules-grep-guard, llm-suite-guard, llm-test-guard, claude-debug-bash-guard, step-log-section-before-spawn, curator-before-committer, single-cycle-agent-in-flight | Discipline enforcement before tool runs |
| `PostToolUse` | (autovalidate inline script for `make llm-phoenix`) | Post-tool validation |
| `PostToolUseFailure` | track-tool-failures | Logs tool failures for diagnostics |
| `SubagentStop` | developer-no-self-gate-reset | Non-build-modes-only: gate verdicts. Dead under the loop (no SubagentStop fires per-role) — loop covers gate exec (`LoopGate`), formatting (`run_format_step`), cycle-state advancement, env-var sample-consistency (`run_env_var_step` → `harnesses/claude/hooks/lib/env-var-sample-scan.sh`, diffs working-tree vs HEAD for undeclared env vars; relocated off committer, which cannot edit `.env.sample`), and curator factcheck + index-parity (`run_curator_doc_check` → `context-factcheck-scan.sh` + `context-index-parity-scan.sh`; 3 claim classes: named-path, count-anchor, id-corruption). `curator-format`, `post-developer-format`, `static-site-build-check`, `stop-gate-failure-breaker`, `stop-spin-guard`, `context-factcheck-curator-stop` deleted (dead-under-loop; live equivalents above already cover each). |
| `Stop` | llm-pending-sweep, pitch-format-validator, build-queue-continuity, stop-resume, stop-verify-planner-gate, role-retrospective-before-stop | End-of-session guards (non-build modes: debug/shape/ops/experiment; role-retrospective-before-stop also fires under the loop) |
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

`harnesses/claude/hooks/lib/context-index-parity-scan.sh` — working-tree scan (no hook I/O): a `context/*.md` add/delete without matching `PROJECT_CONTEXT.md` § Domain Context Files parity is a violation. Used ONLY by the in-loop `run_curator_doc_check` step — cannot be a per-edit gate (an ADD needs BOTH the file AND its row; whichever write lands first would deadlock a PreToolUse gate).

**Satisfy**: Append a row to `PROJECT_CONTEXT.md` § Domain Context Files table with the basename (e.g., `"deployment-topology"` for `context/deployment-topology.md`).

`harnesses/claude/hooks/context-factcheck-edit-gate.sh` — PreToolUse: denies a write to any orientation doc whose PROJECTED post-write content fails `context-factcheck-scan.sh` (materializes projection into a throwaway git-init'd temp mirror). Writer's own turn — same placement rationale as `curator-context-size-gate.sh`. **Doc-root split**: `FACTCHECK_DOC_ROOT` env var reads doc BODY from the mirror; path claims/count probes always resolve against real `repo_root` (1st arg) — mirror-as-repo_root falsely denied every valid claim. Both twins set both. Unset → both read `repo_root` (unchanged default).

## Session Log Role-Event Detection

Cycle logs are append-only JSONL (one JSON object per line, `"ev"` discriminator field) — there is no markdown section structure to pattern-scan anymore. Hooks check session log state via `jq` role-event selectors against the log file:

| Check | Canonical `jq` form |
| - | - |
| role has run (any role) | `jq -e --arg r "<role>" 'select(.ev=="role" and .role==$r)' <file>` |
| planner has run (any stack variant) | `jq -e 'select(.ev=="role" and (.role \| startswith("planner")))' <file>` |
| developer has run (any stack variant) | `jq -e 'select(.ev=="role" and (.role \| startswith("developer-")))' <file>` |
| reviewer has run (any stack variant) | `jq -e 'select(.ev=="role" and (.role \| startswith("reviewer-")))' <file>` |
| concatenated role body text | `jq -r --arg r "<role>" 'select(.ev=="role" and .role==$r)\|.body' <file>` |

`committer` and `context-curator` are stack-agnostic — the role string is always the literal value, no stack suffix. Planner variants (`planner-phoenix`, `planner-static`) are matched via `startswith("planner")` rather than an exact string, so any stack-prefixed planner role satisfies a bare "planner has run" check.

All `jq -e` reads exit 0 = at least one match, exit 1 = none. Wrap in `2>/dev/null` on read paths (swallow malformed-line noise, fail-open) except where a hard block requires certainty. Full event schema and reader forms: session-log rules § Event Schema.

## Retrospective Placement Rule (role-retrospective-before-stop)

`subagent-retrospective-guard.sh` (SubagentStop) and the loop's own post-role warm-resume step were both dead/unwinnable and are deleted — the loop's version sent a prompt asking for bare text but re-checked against a validator requiring a literal header, so a compliant role failed the check every time.

Replaced by **`role-retrospective-before-stop`**, a `Stop`-event hook gating `planner-*|developer-*|reviewer-*` (curator/committer exempt). Claude twin BLOCKS: pushes the role back into its OWN warm session with a reason naming the exact `codegen-log` command. Pi twin is observe-only (warns on stderr — `session_shutdown` cannot block). Checks per role: (1) non-empty `ev:role` body ("work"); (2) EITHER `ev:learned` OR `ev:no_learning` ("learning", or an honest explicit none). Substance, not length, is enforced at the writer — `codegen-log` refuses whole-text placeholder/compliance-echo payloads (exit 2), and never states a passing length in its denial. Bounded at 3 blocks/session (own counter file, distinct from `stop-resume`'s), then falls through with a loud stderr line — never fails the build. `codegen-log section <role> --learned "<text>"` is the one-call compliant path; `append <role> --no-learning "<text>"` is the legal empty-turn exit (session-log rules § Ownership).

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
- Bash guards: `reviewer-guard.sh`, `committer-write-allowlist.sh` (reference the variable)
- Pi twins: `committer-write-allowlist.ts` (hardcoded string with header comment linking to canonical source)
- `registry.yaml`: 2 `match:` lines for the above guards (hardcoded; parity-tested in `make test`)
- `session-log.md` § File Naming (canonical prose)

When the regex changes, update `hooks-lib.sh` first, then regenerate guards via `make install`, then verify all 6 sites match via parity test.

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

`make test` runs multiple targets in sequence including `test-hermetic` (hermetic bash hook tests + hermetic ExUnit) and `npm-ext` (Node.js-based extension tests). A transient race in `npm-ext` can occasionally cause combined `make test` to exit 1 even when both sub-targets pass independently. **Authoritative signal for rule-file changes**: `make test-hermetic`. If `make test` fails but `make test-hermetic` passes, the failure is in `npm-ext` and unrelated to core rule/hook changes.

**Static sentinel co-location tests**: bash tests asserting a sentinel on one specific line (e.g. same-line `SETTINGS_JSON=.*API_FORCE_IDLE_TIMEOUT`) break under variable-indirection refactors. Fix: assert co-location at the variable level (separate assignment-line + reference-line patterns), not literal same-line blob matching — robust to future indirection, still captures the load-bearing invariant.

**Hermetic CI tests vs hooks**: `context-doc-provenance_test.sh` and `context-index-coverage_test.sh` are hermetic bash tests that scan documentation and rules for rotting line-citations and index drift — they are NOT hook/registry entries and do NOT appear in `settings.json`. Auto-discovered via `run-tests.sh` footer detection (`N passed, N failed`). Independent from hook-parity and enforce-registry-parity gates; they are pure linting checks on the content corpus. Corpus scope changes (e.g., widening to include `shared/rules/**/*.md`) are feature additions to the test suite, not hook-registration changes.

## See Also

For matrix of which hooks gate which launcher modes (build vs debug/shape/refactor vs ops), see `context/launcher-hook-matrix.md`.

For hook authoring patterns (how to write/test a hook, output protocol, gate verdict flow, hooks-lib usage, registration mechanics) → `context/hook-authoring-patterns.md`.

For the loop's own gate mechanism (the build path) → `context/test-harness.md`.

## Enforce-Registry-Parity — Compiler-Generated Files & Gate Ordering

`enforce-registry-parity` compares **only** `kind: denial` compiler-generated files (TypeScript in `harnesses/pi/pi-extensions/enforcement/src/hooks/`, Bash in `harnesses/claude/hooks/committer-write-allowlist.sh`) against output from `enforcement_compiler.py`. The `reviewer-guard-session-log-write` registry `id` is `harnesses: pi`-only — it emits a `.ts` file only, no `.sh` counterpart (Claude's reviewer Bash allowlist is `reviewer-bash-allowlist.sh`, a separate `kind: registration` entry). **Hand-authored `kind: registration` hooks are NOT checked by this gate** — registry edits to registration entries flow through `hook-header-parity` (HOOK-MANIFEST header) and `hook-parity` (settings.json) instead. The hook test (`enforce-registry-parity` make target) diffs compiler output with HEAD:

- **Compiler format**: Single-line, compact (no multi-line conditionals)
- **Prettier format**: Multi-line, human-readable (applied at commit time)

If a file is committed with prettier multi-line formatting, the committed version will drift from the compiler's compact single-line output → parity fails.

**Critical gate ordering**: Edit registry → `make install` FIRST (regenerates committed generated files) → `make test`. Reversed order causes `enforce-registry-parity` drift failure. Never run prettier on compiler-generated files.

**Multi-value `role:` compiler case-arm join**: `enforcement_compiler.py`'s `_bash_agent_guard` joins multi-value `role: "a|b"` tokens with `" | "` (space-padded), not a bare `|`, when emitting the bash `case "$AGENT_TYPE" in a | b) ;; ...` guard. `hook_registrations.py`'s role-parity checker (`validate_role_body`) requires EACH token to independently satisfy either `<token>)` (last token) or `<token> |` (space before the pipe, earlier tokens) as a literal substring in the generated body — a bare `a|b)` join leaves every non-last token unmatched, failing `make hook-parity` with "declares role: X but body does not contain...". `reviewer-bash-allowlist` (first generated denial entry with a multi-value role) surfaced this; POSIX `case` syntax accepts space around `|` in patterns, so the fix is compiler-side and applies to all future multi-role generated hooks.

## Quote-Aware Matching — `strip_quoted`/`ignore_quoted`

Command-scanning guards grepping raw `$COMMAND` over-fire on tokens inside quoted spans (remote payloads `ssh host "cat f|head"`, quoted args `grep -n 'git stash' f`) that aren't real local invocations. `strip_quoted`/`stripQuoted` (`hooks-lib.sh`/`hook-helpers.ts`, beside `is_codegen_log_write`) strips quoted spans first — fail-closed: unquoted real invocation still matches/denies, quoted form bypasses.

Compiler `{match_subject}` placeholder + registry `ignore_quoted: true` (no-cat-pipe, no-git-stash) selects strip-wrapped subject vs bare literal (default, byte-identical). `pre-commit-guard` (hand-authored twin, same failure-mode, folded) computes unquoted residue post-carve-out for all git-verb sites.

Excluded: `no-python-json` (stripping disables its intrinsically-quoted `-c "<json>"` form).

## Main-Agent-Scoped Guards (Registration-Based)

Guards scoped to the main-agent session (empty `AGENT_TYPE`/`AGENT_ID`) use `kind: registration` entries — not the `generated: true` denial pipeline. The main-agent session lacks a named role; `role: "*"` would double-cover committer/reviewer allowlists.

**Pattern**: (1) `kind: registration` entry in `registry.yaml` with `role: "*"`, `harnesses: all`; (2) hand-authored `.sh` file with pre-check on `^codegen/logging/` to avoid wrongly denying non-logging writes; (3) `_test.sh` with ≥16 cases; (4) `make install` injects `HOOK-MANIFEST` header + registers in `settings.json`.

**orchestrator-read-discipline hand-authorship**: The `.sh` + `.ts` bodies of `orchestrator-read-discipline` are fully hand-authored (not generated) — the `kind: registration` flag only SKIPS body generation; the `# HOOK-MANIFEST:` header is auto-injected but the body strings are edited directly in both files. When fixing deny-message text, ensure ALL four deny strings are updated in lockstep: the `.sh` top-comment block (deny-message description near `# rationale:`), the `.sh` Read-deny arm (inside the `Read` handler), the `.ts` Bash-deny arm, and the `.ts` Read-deny arm. Omitting any drift-branch causes misdirection in one harness and violates Rule J (parallel hand-authored twins must stay synchronized).

**Path normalization**: Strip leading `./` explicitly (`rel="${rel#./}"`) so both a session-log file and its `./`-prefixed form match the allowlist.

## Shell Case Branching Pattern

Place **specific arms BEFORE wildcards** in shell case statements. Example: a specific `INCONCLUSIVE:render-check-cmd-missing)` arm before a bare `INCONCLUSIVE:*)` arm — first-match semantics ensure the specific handler wins and the wildcard doesn't swallow it. `LoopGate.decide_gate/2` follows the same discipline in Elixir `case` form (see `render-check.js`'s `INCONCLUSIVE:<reason>` verdict vocabulary it dispatches on).

## Git Status Porcelain Parsing

`awk '{print $2}'` on renamed files (`R  old -> new`) extracts only `$2`, truncating the arrow and target. Use `sed 's/^[^ ]* //'` instead — strips leading status code + one space, preserving full paths including renames and spaces. Used by `clean-tree-before-ship.sh` to enumerate uncommitted files in deny message.

## Session-Log Writing (codegen-log Sole-Writer Model)

`codegen-log` is the SOLE writer of cycle logs (append-only JSONL). Raw Edit/Write/Bash writes denied by `session-log-writer-only` hook.

**Core ops**:
- `init --slug <slug>` — create log; loop-only, refuses (exit 2, `.active` untouched) when `CODEGEN_LOG_PATH` set — role MUST NOT `init` inside a cycle.
- `section <role> --slug <slug>` — append `{"ev":"role","role":<role>,"body":<prose>}`.
- `append <role> --slug <slug>` — append `{"ev":"role",...}` event.
- `append <role> --learned "<text>" --slug <slug>` — append `{"ev":"learned",...}`.
- `append <role> --died interrupted|aborted --slug <slug>` — append `{"ev":"died",...}`.
- `append <role> --verdict clear|failed|inconclusive --slug <slug>` — append `{"ev":"gate",...}`.
- `verdict --gate <cmd> --mode <mode> --result "<text>" --slug <slug>` — the loop's dev-gate step verdict writer.
- `relocate --new-slug <slug>` — rename + update `.active`.

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
- **Gate verdict**: the runtime-written gate-result JSON's `.verdict` field is authoritative, never session-log prose. Manual re-runs don't update JSON. Pi build now fails closed on `codegen-build` if the post-dispatch verdict is absent or not `clear`.

## Bash Hook Test Debugging — Silent Crashes & Early Exits

When ALL blocking tests fail while non-blocking pass, **suspect an early fatal crash (unbound var under `set -u`, syntax error) not logic errors** — hook exits non-zero before `block()`, verdict JSON never emitted, looks like "allow" (no block JSON = PASSED).

**Diagnostic**: `bash -x harnesses/claude/hooks/your-hook.sh 2>&1 | head -50` — find where execution stops (typically a var referenced before assignment under `set -u`). Fix by hoisting assignment before first use, or `${var:-}` guard if optional.

**Test implication**: suite flips "all pass"→"all blocking fail" → check unbound-variable crashes first, not logic regression.

## Trigger Keywords

PreToolUse, SubagentStop, Stop hook, Elixir orchestration loop, LoopGate, hook test, run-tests.sh, gate verdict, hook registration, orchestrator hook bypass, resolve_role, ops bypass, per-role gate, AGENT_TYPE gate, gate-result.json verdict, codegen-log, session-log writer, marker flags, .active sentinel, positional-role, slug-class regex, session-log contract
