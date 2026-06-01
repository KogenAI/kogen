# Hooks Domain — Hook System (Bash + Tests)

The hooks domain covers all Claude Code hook scripts, their shared library, registration mechanism, and bash test suite. Hooks fire on `PreToolUse`, `SubagentStop`, and `Stop` lifecycle events — these are the events codegen currently registers; Claude Code supports a larger event catalog (see § Full Claude Code Event Catalog below). Each hook has a paired `_test.sh` file; `run-tests.sh` runs the full suite.

Hook registration: `hook_registrations.py` reads `harnesses/claude/hooks/*.sh`, generates entries in `harnesses/claude/claude-code-settings.json` (source). `install.sh` then copies that file to `~/.claude/settings.json` (installed destination).

## Components

| File                                                         | Purpose                                                                                    |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| `harnesses/claude/hooks/phoenix-dev-gate.sh`                 | SubagentStop — runs Phoenix test suite, appends gate verdict                               |
| `harnesses/claude/hooks/static-site-build-check.sh`          | SubagentStop — builds static site, appends gate verdict                                    |
| `harnesses/claude/hooks/step-log-missing-guard.sh`           | Stop — blocks if dev ran but no step log Write found in transcript                         |
| `harnesses/claude/hooks/stop-cycle-guard.sh`                 | Stop — blocks premature stop before full cycle completes                                   |
| `harnesses/claude/hooks/stop-resume.sh`                      | Stop — resumes orchestration if session was interrupted mid-cycle                          |
| `harnesses/claude/hooks/stop-verify-planner-gate.sh`         | Stop — verifies planner ran before dev delegation                                          |
| `harnesses/claude/hooks/step-log-completeness.sh`            | Stop — checks step log completeness before session ends                                    |
| `harnesses/claude/hooks/llm-pending-sweep.sh`                | Stop — sweeps for pending LLM-generated artifacts before exit                              |
| `harnesses/claude/hooks/session-log-section-integrity.sh`    | PreToolUse — enforces section header presence before Edit                                  |
| `harnesses/claude/hooks/no-python-json.sh`                   | PreToolUse — blocks inline `python3 -c` JSON parsing                                       |
| `harnesses/claude/hooks/no-cat-pipe.sh`                      | PreToolUse — blocks `cat file \| ...` and `head`/`tail` pipe patterns                      |
| `harnesses/claude/hooks/no-git-stash.sh`                     | PreToolUse — blocks `git stash` usage                                                      |
| `harnesses/claude/hooks/orchestrator-no-source-edit.sh`      | PreToolUse — blocks orchestrator from editing source files                                 |
| `harnesses/claude/hooks/orchestrator-no-ci.sh`               | PreToolUse — blocks orchestrator from running CI/test commands                             |
| `harnesses/claude/hooks/orchestrator-read-discipline.sh`     | PreToolUse — blocks orchestrator from reading files it shouldn't                           |
| `harnesses/claude/hooks/subagent-read-discipline.sh`         | PreToolUse — blocks subagents from reading context files they shouldn't                    |
| `harnesses/claude/hooks/pre-commit-guard.sh`                 | PreToolUse — blocks direct `git commit` outside committer role                             |
| `harnesses/claude/hooks/dev-no-ci.sh`                        | PreToolUse — blocks developer from running CI gate commands                                |
| `harnesses/claude/hooks/developer-no-self-gate.sh`           | PreToolUse — blocks developer from running its own gate check                              |
| `harnesses/claude/hooks/planner-guard.sh`                    | PreToolUse — enforces planner constraints (no writes, no bash exec)                        |
| `harnesses/claude/hooks/reviewer-guard.sh`                   | PreToolUse — enforces reviewer constraints                                                 |
| `harnesses/claude/hooks/context-curator-guard.sh`            | PreToolUse — guards context file edits to curator role only                                |
| `harnesses/claude/hooks/context-index-parity.sh`             | PreToolUse — enforces context file + PROJECT_CONTEXT.md index parity                       |
| `harnesses/claude/hooks/operator-subagent-allowlist.sh`      | PreToolUse — enforces agent delegation allowlist                                           |
| `harnesses/claude/hooks/build-worker-cwd-guard.sh`           | PreToolUse — guards build worker cwd discipline                                            |
| `harnesses/claude/hooks/build-no-success-before-commit.sh`   | PreToolUse — blocks declaring success before commit completes                              |
| `harnesses/claude/hooks/committer-no-trailer-guard.sh`       | PreToolUse — blocks commit trailers (Co-authored-by, etc.)                                 |
| `harnesses/claude/hooks/committer-single-line-guard.sh`      | PreToolUse — enforces single-line commit subject                                           |
| `harnesses/claude/hooks/committer-subject-length.sh`         | PreToolUse — enforces commit subject line length limit                                     |
| `harnesses/claude/hooks/phoenix-backend-developer-guard.sh`  | PreToolUse — guards backend developer file scope                                           |
| `harnesses/claude/hooks/phoenix-frontend-developer-guard.sh` | PreToolUse — guards frontend developer file scope                                          |
| `harnesses/claude/hooks/static-site-ex-guard.sh`             | PreToolUse — blocks .ex file writes in static site context                                 |
| `harnesses/claude/hooks/session-log-section-integrity.sh`    | PreToolUse — enforces session log section header rules                                     |
| `harnesses/claude/hooks/subagent-retrospective-guard.sh`     | SubagentStop — validates retrospective placement in step log                               |
| `harnesses/claude/hooks/post-developer-format.sh`            | SubagentStop — runs code formatter after developer completes                               |
| `harnesses/claude/hooks/developer-no-self-gate-reset.sh`     | SubagentStop — blocks developer from resetting its own gate                                |
| `harnesses/claude/hooks/track-subagent-edits.sh`             | PreToolUse — tracks files edited per subagent for session log                              |
| `harnesses/claude/hooks/track-tool-failures.sh`              | PostToolUseFailure — logs tool failures for diagnostics                                    |
| `harnesses/claude/hooks/usage-rules-grep-guard.sh`           | PreToolUse — enforces grep usage rules (no bare grep on files)                             |
| `harnesses/claude/hooks/env-var-sample-consistency.sh`       | PreToolUse — checks env var sample file consistency                                        |
| `harnesses/claude/hooks/llm-suite-guard.sh`                  | PreToolUse — guards LLM test suite invocations                                             |
| `harnesses/claude/hooks/llm-test-guard.sh`                   | PreToolUse — guards individual LLM test invocations                                        |
| `harnesses/claude/hooks/claude-debug-bash-guard.sh`          | PreToolUse — bash guards in claude-debug mode                                              |
| `harnesses/claude/hooks/claude-inspector-bash-guard.sh`      | PreToolUse — bash guards in claude-inspector mode                                          |
| `harnesses/claude/hooks/claude-inspector-read-guard.sh`      | PreToolUse — read guards in claude-inspector mode                                          |
| `harnesses/claude/hooks/claude-inspector-write-guard.sh`     | PreToolUse — write guards in claude-inspector mode                                         |
| `harnesses/claude/hooks/lib/hooks-lib.sh`                    | Shared bash library: `session_log_from_transcript`, transcript JSONL parsing, path helpers |
| `harnesses/claude/hooks/lib/gate-select.sh`                  | Selects appropriate gate script based on stack detected                                    |
| `harnesses/claude/hooks/run-tests.sh`                        | Runs all `*_test.sh` hook tests                                                            |

## Hook Event Types and Scripts

Event → script mapping from `harnesses/claude/claude-code-settings.json`:

| Event                | Hook Scripts (key ones)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Purpose                                    |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `PreToolUse`         | no-cat-pipe, no-python-json, no-git-stash, orchestrator-no-source-edit, orchestrator-no-ci, orchestrator-read-discipline, subagent-read-discipline, pre-commit-guard, dev-no-ci, developer-no-self-gate, planner-guard, reviewer-guard, context-curator-guard, context-index-parity, operator-subagent-allowlist, build-worker-cwd-guard, build-no-success-before-commit, committer-no-trailer-guard, committer-single-line-guard, committer-subject-length, phoenix-backend-developer-guard, phoenix-frontend-developer-guard, static-site-ex-guard, session-log-section-integrity, track-subagent-edits, usage-rules-grep-guard, env-var-sample-consistency, llm-suite-guard, llm-test-guard, claude-debug-bash-guard, claude-inspector-\* | Discipline enforcement before tool runs    |
| `PostToolUse`        | (autovalidate inline script for `make llm-phoenix`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Post-tool validation                       |
| `PostToolUseFailure` | track-tool-failures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Logs tool failures for diagnostics         |
| `SubagentStop`       | developer-no-self-gate-reset, phoenix-dev-gate, post-developer-format, static-site-build-check, subagent-retrospective-guard                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Gate verdicts + post-dev formatting        |
| `Stop`               | llm-pending-sweep, step-log-completeness, step-log-missing-guard, stop-cycle-guard, stop-resume, stop-verify-planner-gate                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | End-of-session guards and resumption       |
| `UserPromptSubmit`   | (inline: `/orchestrate` session state capture)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Session routing for `/orchestrate` command |
| `SessionStart`       | (inline: orchestrate session context restore)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Restores context after compact             |
| `SessionEnd`         | (inline: cleans up orchestrate session JSON)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Cleanup                                    |

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
  appends "ALL CLEAR ✅" / "FAILED ❌" / "INCONCLUSIVE ⚠️ <class>" to step log ## dev-gate Section
```

Orchestrator reads verdict before deciding next delegation.

## Pitfalls

- **Hook tests are bash, not ExUnit** — run via `run-tests.sh`, not `mix test`
- **`session_log_from_transcript`** filters Write/Edit/MultiEdit tool_use in transcript JSONL; Bash redirects (`echo >`) are invisible to it → always use Write tool for step logs
- **Hook registration is not in manifest** — `hook_registrations.py` owns it independently; manifest only documents that hooks exist
- **Per-harness hook strategy** — hooks under `harnesses/claude/hooks/` are Claude-specific; Pi harness enforcement runs through Pi extension system (`harnesses/pi/pi-extensions/enforcement/`), not bash hooks. Do not assume Claude hooks apply to Pi harness.
- **Hook table is selective** — the Components table lists all ~45 hook scripts; see `harnesses/claude/hooks/` directory for the definitive list as it may grow
