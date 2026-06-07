# Hooks Domain — Hook System (Bash + Tests)

The hooks domain covers all Claude Code hook scripts, their shared library, registration mechanism, and bash test suite. Hooks fire on `PreToolUse`, `SubagentStop`, and `Stop` lifecycle events — these are the events codegen currently registers; Claude Code supports a larger event catalog (see § Full Claude Code Event Catalog below). Each hook has a paired `_test.sh` file; `run-tests.sh` runs the full suite.

Hook registration: `hook_registrations.py` reads `harnesses/claude/hooks/*.sh`, generates entries in `harnesses/claude/claude-code-settings.json` (source). `install.sh` then copies that file to `~/.claude/settings.json` (installed destination).

## Components

| File                                                         | Purpose                                                                                                                            |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `harnesses/claude/hooks/phoenix-dev-gate.sh`                 | SubagentStop — runs Phoenix test suite + render check, appends gate verdict                                                        |
| `harnesses/claude/hooks/static-site-build-check.sh`          | SubagentStop — builds static site + render check, appends gate verdict                                                             |
| `harnesses/claude/hooks/pitch-format-validator.sh`           | Stop — validates ## Questions/## Answers/> Status: grammar in active pitch for shape/refactor/ops sessions                         |
| `harnesses/claude/hooks/step-log-missing-guard.sh`           | Stop — blocks if dev ran but no step log Write found in transcript                                                                 |
| `harnesses/claude/hooks/stop-cycle-guard.sh`                 | Stop — blocks premature stop before full cycle completes                                                                           |
| `harnesses/claude/hooks/stop-resume.sh`                      | Stop — resumes orchestration if session was interrupted mid-cycle                                                                  |
| `harnesses/claude/hooks/stop-verify-planner-gate.sh`         | Stop — verifies planner ran before dev delegation                                                                                  |
| `harnesses/claude/hooks/step-log-completeness.sh`            | Stop — checks step log completeness before session ends                                                                            |
| `harnesses/claude/hooks/llm-pending-sweep.sh`                | Stop — sweeps for pending LLM-generated artifacts before exit                                                                      |
| `harnesses/claude/hooks/session-log-section-integrity.sh`    | PreToolUse — enforces section header presence before Edit                                                                          |
| `harnesses/claude/hooks/no-python-json.sh`                   | PreToolUse — blocks inline `python3 -c` JSON parsing                                                                               |
| `harnesses/claude/hooks/no-cat-pipe.sh`                      | PreToolUse — blocks `cat file \| ...` and `head`/`tail` pipe patterns                                                              |
| `harnesses/claude/hooks/no-git-stash.sh`                     | PreToolUse — blocks `git stash` usage                                                                                              |
| `harnesses/claude/hooks/orchestrator-no-source-edit.sh`      | PreToolUse — blocks orchestrator from editing source files                                                                         |
| `harnesses/claude/hooks/orchestrator-no-ci.sh`               | PreToolUse — blocks orchestrator from running CI/test commands                                                                     |
| `harnesses/claude/hooks/orchestrator-read-discipline.sh`     | PreToolUse — blocks orchestrator from reading files it shouldn't                                                                   |
| `harnesses/claude/hooks/subagent-read-discipline.sh`         | PreToolUse — blocks subagents from reading context files they shouldn't                                                            |
| `harnesses/claude/hooks/pre-commit-guard.sh`                 | PreToolUse — blocks direct `git commit` outside committer role                                                                     |
| `harnesses/claude/hooks/dev-no-ci.sh`                        | PreToolUse — blocks developer from running CI gate commands                                                                        |
| `harnesses/claude/hooks/developer-no-self-gate.sh`           | PreToolUse — blocks developer from running its own gate check                                                                      |
| `harnesses/claude/hooks/planner-guard.sh`                    | PreToolUse — enforces planner constraints (no writes, no bash exec)                                                                |
| `harnesses/claude/hooks/reviewer-guard.sh`                   | PreToolUse — enforces reviewer constraints                                                                                         |
| `harnesses/claude/hooks/context-curator-guard.sh`            | PreToolUse — guards context file edits to curator role only                                                                        |
| `harnesses/claude/hooks/context-index-parity.sh`             | PreToolUse — enforces context file + PROJECT_CONTEXT.md index parity                                                               |
| `harnesses/claude/hooks/curator-before-committer.sh`         | PreToolUse — blocks committer spawn before context-curator has run                                                                 |
| `harnesses/claude/hooks/operator-subagent-allowlist.sh`      | PreToolUse — enforces agent delegation allowlist (role ∈ {debug, shape, refactor, ops}); gates slash commands that spawn subagents |
| `harnesses/claude/hooks/build-worker-cwd-guard.sh`           | PreToolUse — guards build worker cwd discipline                                                                                    |
| `harnesses/claude/hooks/build-no-success-before-commit.sh`   | PreToolUse — blocks declaring success before commit completes                                                                      |
| `harnesses/claude/hooks/committer-no-trailer-guard.sh`       | PreToolUse — blocks commit trailers (Co-authored-by, etc.)                                                                         |
| `harnesses/claude/hooks/committer-single-line-guard.sh`      | PreToolUse — enforces single-line commit subject                                                                                   |
| `harnesses/claude/hooks/committer-subject-length.sh`         | PreToolUse — enforces commit subject line length limit                                                                             |
| `harnesses/claude/hooks/phoenix-backend-developer-guard.sh`  | PreToolUse — guards backend developer file scope                                                                                   |
| `harnesses/claude/hooks/phoenix-frontend-developer-guard.sh` | PreToolUse — guards frontend developer file scope                                                                                  |
| `harnesses/claude/hooks/static-site-ex-guard.sh`             | PreToolUse — blocks .ex file writes in static site context                                                                         |
| `harnesses/claude/hooks/session-log-section-integrity.sh`    | PreToolUse — enforces session log section header rules                                                                             |
| `harnesses/claude/hooks/subagent-retrospective-guard.sh`     | SubagentStop — validates retrospective placement in step log                                                                       |
| `harnesses/claude/hooks/post-developer-format.sh`            | SubagentStop — runs code formatter after developer completes                                                                       |
| `harnesses/claude/hooks/developer-no-self-gate-reset.sh`     | SubagentStop — blocks developer from resetting its own gate                                                                        |
| `harnesses/claude/hooks/track-subagent-edits.sh`             | PreToolUse — tracks files edited per subagent for session log                                                                      |
| `harnesses/claude/hooks/track-tool-failures.sh`              | PostToolUseFailure — logs tool failures for diagnostics                                                                            |
| `harnesses/claude/hooks/usage-rules-grep-guard.sh`           | PreToolUse — enforces grep usage rules (no bare grep on files)                                                                     |
| `harnesses/claude/hooks/env-var-sample-consistency.sh`       | PreToolUse — checks env var sample file consistency                                                                                |
| `harnesses/claude/hooks/llm-suite-guard.sh`                  | PreToolUse — guards LLM test suite invocations                                                                                     |
| `harnesses/claude/hooks/llm-test-guard.sh`                   | PreToolUse — guards individual LLM test invocations                                                                                |
| `harnesses/claude/hooks/claude-debug-bash-guard.sh`          | PreToolUse — bash guards in claude-debug mode                                                                                      |
| `harnesses/claude/hooks/claude-inspector-bash-guard.sh`      | PreToolUse — bash guards in claude-inspector mode                                                                                  |
| `harnesses/claude/hooks/claude-inspector-read-guard.sh`      | PreToolUse — read guards in claude-inspector mode                                                                                  |
| `harnesses/claude/hooks/claude-inspector-write-guard.sh`     | PreToolUse — write guards in claude-inspector mode                                                                                 |
| `harnesses/claude/hooks/lib/hooks-lib.sh`                    | Shared bash library: `session_log_from_transcript`, `pitch_from_transcript`, transcript JSONL parsing, path helpers                |
| `harnesses/claude/hooks/lib/gate-select.sh`                  | Selects gate command from ```gate-json block (jq-parsed) or prose `**Gate**:`fallback; emits`gate=`, `mode=`, `timeout=` lines     |
| `harnesses/claude/hooks/lib/gate-result.sh`                  | Shared helper: `write_gate_result` writes structured `codegen/gate-pending/gate-result.json`; `gate_result_verdict` reads verdict  |
| `harnesses/claude/hooks/lib/gate-control.sh`                 | PID-liveness helper: `gate_control_status` checks in-flight gate; `gate_control_kill` terminates; used by stop-cycle-guard         |
| `harnesses/claude/hooks/lib/render-check.js`                 | Headless Chromium render verdict engine: DOM non-empty, styles applied, no JS errors                                               |
| `harnesses/claude/hooks/run-tests.sh`                        | Runs all `*_test.sh` hook tests                                                                                                    |

## Hook Event Types and Scripts

Event → script mapping from `harnesses/claude/claude-code-settings.json`:

| Event                | Hook Scripts (key ones)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Purpose                                    |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `PreToolUse`         | no-cat-pipe, no-python-json, no-git-stash, orchestrator-no-source-edit, orchestrator-no-ci, orchestrator-read-discipline, subagent-read-discipline, pre-commit-guard, dev-no-ci, developer-no-self-gate, planner-guard, reviewer-guard, context-curator-guard, context-index-parity, curator-before-committer, operator-subagent-allowlist, build-worker-cwd-guard, build-no-success-before-commit, committer-no-trailer-guard, committer-single-line-guard, committer-subject-length, phoenix-backend-developer-guard, phoenix-frontend-developer-guard, static-site-ex-guard, session-log-section-integrity, track-subagent-edits, usage-rules-grep-guard, env-var-sample-consistency, llm-suite-guard, llm-test-guard, claude-debug-bash-guard, claude-inspector-\* | Discipline enforcement before tool runs    |
| `PostToolUse`        | (autovalidate inline script for `make llm-phoenix`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Post-tool validation                       |
| `PostToolUseFailure` | track-tool-failures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Logs tool failures for diagnostics         |
| `SubagentStop`       | developer-no-self-gate-reset, phoenix-dev-gate, post-developer-format, static-site-build-check, subagent-retrospective-guard                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Gate verdicts + post-dev formatting        |
| `Stop`               | llm-pending-sweep, pitch-format-validator, step-log-completeness, step-log-missing-guard, stop-cycle-guard, stop-resume, stop-verify-planner-gate                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | End-of-session guards and resumption       |
| `UserPromptSubmit`   | (inline: `/orchestrate` session state capture)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Session routing for `/orchestrate` command |
| `SessionStart`       | (inline: orchestrate session context restore)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Restores context after compact             |
| `SessionEnd`         | (inline: cleans up orchestrate session JSON)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Cleanup                                    |

### Full Claude Code Event Catalog

Claude Code exposes the following lifecycle events. Codegen registers only the subset listed in the table above; events not in that table are unused by codegen today.

| Event                 | Notes                                                  |
| --------------------- | ------------------------------------------------------ |
| `SessionStart`        | Fires when a new session begins                        |
| `Setup`               | Environment setup phase before first turn              |
| `UserPromptSubmit`    | Fires when user submits a prompt                       |
| `UserPromptExpansion` | Fires when a prompt is expanded (e.g. slash command)   |
| `PreToolUse`          | **Registered by codegen** — fires before any tool call |
| `PermissionRequest`   | Fires when a tool requests permission                  |
| `PermissionDenied`    | Fires when a permission request is denied              |
| `PostToolUse`         | **Registered by codegen** (selectively) — after tool   |
| `PostToolUseFailure`  | **Registered by codegen** — fires on tool failure      |
| `PreCompact`          | Fires before context compaction                        |
| `PostCompact`         | Fires after context compaction completes               |
| `SubagentStart`       | Fires when a subagent Task spawns                      |
| `SubagentStop`        | **Registered by codegen** — fires when subagent stops  |
| `Stop`                | **Registered by codegen** — fires when session stops   |
| `Notification`        | General notification event                             |
| `SessionEnd`          | **Registered by codegen** (inline) — session teardown  |

## curator-before-committer Guard

`harnesses/claude/hooks/curator-before-committer.sh` — PreToolUse/Agent hook that blocks the orchestrator from spawning the committer before context-curator has run.

**What it does**: intercepts every `Agent` tool call; if `subagent_type == "committer"`, checks the active step log for section headers. If a `## reviewer-*` section exists but no `## context-curator Section` is found, the spawn is denied with an explanation.

**When it fires**: reviewer approved (reviewer section present in log) AND committer spawn attempted AND curator has not yet run.

**Fail-open**: if no active step log can be located from the session transcript (e.g. very first spawn before any log write), the hook exits 0 → allows. State cannot be determined → do not block.

**Why it exists**: the orchestrator prompts historically said "spawn committer after reviewer" and often skipped curator. This hook makes the reviewer → context-curator → committer ordering a hard constraint enforced at spawn time, not just a soft suggestion in the prompt. Prevents stray commits authored by curator (changes intended for context files only should not be committed until curator role completes its own work).

**Pi mirror**: `harnesses/pi/pi-extensions/enforcement/src/hooks/curator-before-committer.ts` — same logic via `tool_call` event on `"subagent"` tool name.

**Orchestrator ordering**: All four cycle statements in both harnesses' build prompt (`harnesses/claude/tools-header/build.txt` and `harnesses/pi/tools-header/build.txt`) name the full sequence: `reviewer → context-curator → committer`. The prompt alone is not enough — the spawn-time guard provides enforcement at the moment committer delegation is attempted.

## context-curator-guard Write Surface

`harnesses/claude/hooks/context-curator-guard.sh` — PreToolUse hook that restricts curator to its allowed write surface. Fires only when `AGENT_TYPE == "context-curator"` and tool is `Edit|Write|MultiEdit`.

**Allowed patterns (exact lines in hook source)**:

- Line 46: `(^|/)context/` — allows `context/**` in any project
- Line 51: `(^|/)codegen/rules(/|$)` — allows `codegen/rules/**` symlink path in any project (symlink target is `<codegen-repo>/shared/rules`)
- Line 56: `(^|/)codegen/logging/` — allows `codegen/logging/**` session logs

**Path-nesting and symlink mechanics**: all curators (codegen-on-codegen and downstream) use the symlink path.

- All repos: `codegen-scaffold` creates `<project>/codegen/rules` as a symlink pointing to `<codegen-repo>/shared/rules` (absolute). The hook receives the **symlink path** — NOT the resolved target — so the path seen is `<project>/codegen/rules/foo.md`. Pattern `(^|/)codegen/rules(/|$)` matches → ALLOWED.
- Codegen-on-codegen: same symlink exists at `<codegen-repo>/codegen/rules` → use `codegen/rules/<path>` path, not `shared/rules/<path>` directly.

**Important**: Direct `shared/rules/` paths are DENIED — only the `codegen/rules/` symlink path is allowed. Boundary cases that must still be DENIED: `codegen/recipes/`, `codegen/rulesets/` — the pattern anchors on `/rules(/|$)` so these do not match.

Cross-reference: curator decision tree → `context/rules-roles.md` § Curator Write Surface; rule text → `shared/rules/roles/context-curator.md` § Write Surface.

## context-index-parity Guard

`harnesses/claude/hooks/context-index-parity.sh` — **PreToolUse (staging) + commit-time enforcement** — ensures context file additions are reflected in `PROJECT_CONTEXT.md` Domain Context Files table.

**What it does**: When a `context/*.md` file is staged for addition (`git add context/foo.md`), the hook checks if `PROJECT_CONTEXT.md` is also staged AND its body contains the file's basename (`grep -qF "foo"`). Hook blocks Edit of either file if parity is broken.

**Timing**: **Not a `make test` gate.** Fires during `git add` (staging) and is a commit-time block — the committer role will be unable to commit if a new `context/*.md` was added without a corresponding `PROJECT_CONTEXT.md` Domain Context Files table row.

**Why it matters**: `PROJECT_CONTEXT.md` is the index that the planner uses to route work and select context files for delegation. A new context file without an index entry is invisible to the planner. The hook ensures the two stay synchronized.

**How to satisfy it**: When adding a new context file, append a row to `PROJECT_CONTEXT.md` § Domain Context Files table with the file's basename in one of the table columns (typically the first column, the filename). The basename string (e.g., `"deployment-topology"` for `context/deployment-topology.md`) must appear in the staged `PROJECT_CONTEXT.md` body.

## Session Log Section Detection

Hooks that check session log state use the `## <role>.*Section` pattern to detect agent completion:

- `## reviewer-*` (any role variant, e.g., `reviewer-phoenix`, `reviewer-static`) — indicates reviewer has run
- `## context-curator Section` (literal name, no variant) — indicates curator has run
- `## developer-*`, `## planner Section` — other agent sections (literal for planner, variant for developer)

This pattern is used by:

- `curator-before-committer.sh` — checks for `## reviewer-*` AND missing `## context-curator Section`
- `step-log-completeness.sh` — verifies all expected sections present before session end

The curator section header uses the literal name `## context-curator Section` (no stack variant, unlike developer/reviewer) because curator is stack-agnostic and always named identically regardless of consuming app type.

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
- **rules**: hooks enforce rules at runtime (e.g. `no-python-json.sh` → `bash-discipline.md` rule). Hooks own verdict _generation_ (appending gate result to step log); for verdict _reaction_ logic (what orchestrator does after reading verdict), see `context/rules-roles.md` (orchestrator rules)
- **test-harness**: hook tests (`*_test.sh`) are bash scripts; `run-tests.sh` runs them separately from ExUnit suite

## Hook Output Protocol

Hook scripts communicate decisions back to Claude Code via JSON on stdout. The shape varies by event type.

**Decision field (top-level `decision`)** — applies to: `Stop`, `SubagentStop`, `PreCompact`, `UserPromptSubmit`, `PostToolUse`:

```json
{
  "decision": "block",
  "reason": "Human-readable explanation shown to the model"
}
```

Omitting `decision` (or exiting 0 with no JSON) means "proceed". Non-zero exit code also blocks.

**PreToolUse — permission decision** — uses `hookSpecificOutput.permissionDecision`:

```json
{
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "reason": "Denied by no-git-stash.sh: git stash is forbidden"
  }
}
```

Valid `permissionDecision` values:

| Value   | Meaning                                           |
| ------- | ------------------------------------------------- |
| `allow` | Explicitly allow this tool call                   |
| `deny`  | Block this tool call, surface reason to model     |
| `ask`   | Escalate to user for interactive approval         |
| `defer` | No opinion — let Claude Code apply default policy |

**Events codegen does not yet use** — for `PreCompact`, `PermissionRequest`, `PostCompact`, `SubagentStart`, and other unregistered events, verify the exact field shape against https://code.claude.com/docs/en/hooks before relying on them. Codegen has not exercised these events in production; the protocol above is confirmed only for the events in the registered subset.

## Gate Verdict Flow

```
SubagentStop fires → gate-select.sh picks stack →
  phoenix-dev-gate.sh (mix test) OR static-site-build-check.sh (npm run build) →
  writes codegen/gate-pending/gate-result.json (structured verdict file) →
  appends "ALL CLEAR ✅" / "FAILED ❌" / "INCONCLUSIVE ⚠️ <class>" to step log ## dev-gate Section
```

Orchestrator reads verdict before deciding next delegation.

**Structured result file** (`<project>/codegen/gate-pending/gate-result.json`):

- Written by `write_gate_result` (from `lib/gate-result.sh`) on every gate branch to `<project>/codegen/gate-pending/gate-result.json` (created at session start by gate-select.sh)
- Fields: `gate`, `mode`, `verdict` (clear|failed|inconclusive), `exit_code`, `execution_evidence`, `expected_segments`, `render_verdict`, `classification`, `started_at`, `ended_at`, `session_id`, `log`, `runner_found`
- `build-no-success-before-commit.sh` reads `verdict` field — requires `clear` before allowing BUILD_RESULT signal
- `stop-cycle-guard.sh` reads `verdict` field — cross-checks log emoji with structured verdict
- `step-log-completeness.sh` reads `verdict` field — `clear` enables completion even without log ALL CLEAR marker

**Gate JSON block format** (new — `gate-select.sh` parses gate-json fence in `## Plan`):

```gate-json
{
  "command": "make ci",
  "mode": "short",
  "timeout": 900
}
```

Gate-json block scoping: block is parsed ONLY when it immediately follows the `**Gate**:` line (up to one blank line); example/documentation blocks elsewhere in the plan body are ignored. This prevents format documentation from being misidentified as the authoritative gate spec. Prose `**Gate**: make ci` still accepted as fallback for backward compat.

**Gate Scope — Codegen Output Only**: Gates validate the _generated harness and codegen artifacts_ (e.g., hook unit tests, scaffold output compilation in test_harness). Gates do NOT validate downstream project state, symlink health, or consumer setup. Downstream validation belongs in the consuming app's own CI — that is where `curator-guard` will catch stale symlinks and fail loudly. This one-way boundary keeps codegen focused on artifact generation and prevents coupling to consumer-specific paths or assumptions.

## Hook Placement & Interception Points

New guards can be added to codegen by following established patterns:

**Claude Code** (`harnesses/claude/hooks/`)

- `PreToolUse` on `Agent` tool + `tool_input.subagent_type == "name"` match — intercepts subagent spawning (e.g., `curator-before-committer.sh` blocks committer spawn)
- `PreToolUse` on any tool — blocks arbitrary tool calls (e.g., `no-git-stash.sh` blocks `git stash`)
- `SubagentStop` — fires when a subagent completes, for post-agent logic (e.g., `phoenix-dev-gate.sh` appends gate verdict)
- `Stop` — fires at session end for final guards (e.g., `step-log-completeness.sh` checks log integrity before exit)

**Pi harness** (`harnesses/pi/pi-extensions/enforcement/src/hooks/`)

- `tool_call` on `"subagent"` tool name — Pi mirror of Claude's `Agent` PreToolUse matchers (e.g., `curator-before-committer.ts`)
- `tool_call` on any tool name — Pi mirror of Claude's PreToolUse guards
- `subagent_stop` — Pi mirror of Claude's SubagentStop
- `tool_use_error` — Pi error handling (no strict Claude equivalent)

Both harnesses use the same hook file naming, same test patterns (`*_test.sh` / `*_test.ts`), and fail-open semantics (missing state → allow).

## See Also

For matrix of which hooks gate which launcher modes (build vs debug/shape/refactor vs ops), see `context/launcher-hook-matrix.md`.

## Gate Pre-Flight Logic (phoenix-dev-gate.sh)

Gate execution has two distinct code paths:

1. **Pre-flight check** (lines 264–276): Verifies gate runner (`make`, `mix`) is on PATH via `command -v`. Fails immediately if missing.
2. **Gate execution + exit-code handling** (lines 279–293): Runs the gate command; classifies exit codes:
   - Exit 0 → gate passed
   - Exit 126/127 → command not found / not executable (separate from pre-flight path)
   - Other non-zero → gate failed

**Test fixture implications**: Tests that stub `make` to exit 127 exercise the gate-execution path (exit-code handling), NOT the pre-flight check (command-v path). These are two separate codepaths — testing one does not imply the other is working. Pre-flight is a quick guard; gate-execution is the main path where rendering checks and verdict appending occur.

## Enforce-Registry-Parity — TypeScript Compiler-Generated Files

`enforce-registry-parity` compares committed TypeScript files (in `harnesses/pi/pi-extensions/enforcement/src/hooks/`) against output from `enforcement_compiler.py`. The hook test (`enforce-registry-parity` make target) diffs compiler output with HEAD:

- **Compiler format**: Single-line, compact (no multi-line conditionals)
- **Prettier format**: Multi-line, human-readable (applied at commit time)

If a file is committed with prettier multi-line formatting, the committed version will drift from the compiler's compact single-line output → parity fails.

**Fix**: Never run prettier on compiler-generated TypeScript files. Compiler output is the single source of truth. If a `.ts` file must be human-formatted, ensure it is either:

1. Not generated by the compiler, or
2. Reformatted by the compiler after generation (currently not done)

Run `make install` after any enforcement rule change to regenerate the `.ts` files, then verify `make enforce-registry-parity` passes before commit.

## Pitfalls

- **Hook tests are bash, not ExUnit** — run via `run-tests.sh`, not `mix test`
- **`session_log_from_transcript`** filters Write/Edit/MultiEdit tool_use in transcript JSONL; Bash redirects (`echo >`) are invisible to it → always use Write tool for step logs
- **Gate-json awk scoping** — `gate-select.sh` awk pattern must require gate-json block to immediately follow `**Gate**:` line; use `after_gate=1` on line match, then enter block mode only if next non-blank line is ` ```gate-json `. Free-floating example blocks in plan body are otherwise misidentified as authoritative gates.
- **Hook registration is not in manifest** — `hook_registrations.py` owns it independently; manifest only documents that hooks exist
- **Per-harness hook strategy** — hooks under `harnesses/claude/hooks/` are Claude-specific; Pi harness enforcement runs through Pi extension system (`harnesses/pi/pi-extensions/enforcement/`), not bash hooks. Do not assume Claude hooks apply to Pi harness.
- **Hook table is selective** — the Components table lists all ~45 hook scripts; see `harnesses/claude/hooks/` directory for the definitive list as it may grow
