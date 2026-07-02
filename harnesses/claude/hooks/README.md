# Claude Code Hooks — Reference

Hook scripts in this directory are installed into `.claude/hooks/` for each project via `make install` in the OCG codegen repo. They enforce role-based constraints as `PreToolUse`, `PostToolUse`, and `Stop` event hooks.

## Hook Execution Order

Claude Code fires hooks in the order declared in `.claude/settings.json`. For a given tool call, **all matching `PreToolUse` hooks run**; the first `deny` wins (remaining hooks may or may not run depending on Claude Code's implementation, but a deny is final).

Typical firing order for common roles:

### Orchestrator (top-level, no `agent_id`)

| Event          | Hooks that fire                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `Bash`         | `orchestrator-read-discipline`, `no-cat-pipe`, `no-git-stash`, `no-python-json`, `build-worker-cwd-guard`, `session-log-writer-only` |
| `Edit`/`Write` | `orchestrator-no-source-edit`, `session-log-writer-only`, `build-worker-cwd-guard`                                                   |

### Developer (`agent_type=developer-phoenix-backend` / `developer-phoenix-frontend`)

| Event                      | Hooks that fire                                                                         |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `Bash`                     | `dev-no-ci`, `no-cat-pipe`, `no-python-json`, `no-git-stash`, `session-log-writer-only` |
| `Edit`/`Write`/`MultiEdit` | `session-log-writer-only`, `track-subagent-edits`, `env-var-sample-consistency`         |
| `PostToolUse` (failure)    | `track-tool-failures`                                                                   |

### Planner (`agent_type=planner`)

| Event               | Hooks that fire                                       |
| ------------------- | ----------------------------------------------------- |
| `Bash`              | `planner-guard`, `planner-load-discipline`            |
| `Edit`              | `planner-guard` (only `codegen/logging/*.md` allowed) |
| `Write`/`MultiEdit` | `planner-guard` (always denied)                       |

### Inspector (`agent_type=inspector` / `inspector-phoenix`)

| Event          | Hooks that fire                |
| -------------- | ------------------------------ |
| `Bash`         | `claude-inspector-bash-guard`  |
| `Edit`/`Write` | `claude-inspector-write-guard` |
| `Read`         | `claude-inspector-read-guard`  |

### Committer (`agent_type=committer`)

| Event               | Hooks that fire                                |
| ------------------- | ---------------------------------------------- |
| `Bash` (git commit) | `committer-subject-length`, `pre-commit-guard` |

### Debug (`CLAUDE_ROLE=debug`)

| Event          | Hooks that fire                                           |
| -------------- | --------------------------------------------------------- |
| `Bash`         | `claude-debug-bash-guard`                                 |
| `Edit`/`Write` | `orchestrator-no-source-edit` (deny — debug is read-only) |

---

## Policy Summary

| Role         | Bash writes           | File writes                               | Git       | Notes                       |
| ------------ | --------------------- | ----------------------------------------- | --------- | --------------------------- |
| Orchestrator | mkdir/log only        | codegen/logging/, codegen/pitches/, /tmp/ | read-only | no source edits             |
| Developer    | any (no `make ci`)    | any                                       | read-only | no CI gates                 |
| Planner      | read-only + /tmp/     | codegen/logging/ only                     | read-only | investigation only          |
| Inspector    | none                  | none                                      | read-only | read-only investigation     |
| Committer    | `git commit/add/push` | none                                      | write     | subject ≤50B                |
| Debug        | none (read-only)      | none                                      | read-only | investigation, no mutations |

---

## Hook Descriptions

### Blocking hooks (deny on violation)

- **`orchestrator-no-source-edit`** — Restricts orchestrator writes per launcher. Plain orchestrator (no `CLAUDE_ROLE`, also covers `claude-build`) writes allowed under `codegen/logging/`, `codegen/pitches/`, and absolute `/tmp/`. `claude-debug` / `claude-shape` (`CLAUDE_ROLE=debug|shape`) writes scoped to `codegen/pitches/` only — for both the orchestrator and Agent-spawned helpers. Subagents under plain orchestrator bypass the hook.
- **`claude-inspector-bash-guard`** — Blocks filesystem mutations, git writes, SQL mutations, path traversal (`../`), and redirect writes for inspector agents. Other agent types pass through.
- **`build-worker-cwd-guard`** — In user-app context (the platform apps_root), prevents orchestrator from reading/writing outside the user app directory.
- **`planner-guard`** — Restricts planner to read-only bash, Edit on `codegen/logging/*.md` only, no `Write`/`MultiEdit`. Both src AND dest must be in allowed dirs for `mv`.
- **`planner-load-discipline`** — Blocks planner from loading usage_rules files directly (recipes are loaded on demand via recipes/; rules are baked into subagents).
- **`committer-subject-length`** — Blocks `git commit -m "subject"` where subject exceeds 50 bytes. Heredoc form denied (can't extract subject).
- **`dev-no-ci`** — Blocks developers from running `make ci`, `make llm`, `make llm-phoenix`. Gate commands run via the loop's `LoopGate` (non-interactive builds) or a SubagentStop hook (interactive-session fallback).
- **`claude-debug-bash-guard`** — In debug sessions (`CLAUDE_ROLE=debug`), blocks: recursive rm, DB migrations, git writes, mix deps.get, seeds, destructive SQL, curl mutations (POST/PUT/PATCH/DELETE), docker mutations, systemctl/launchctl mutations, kill/pkill, package installs.
- **`session-log-writer-only`** — `codegen-log` is the SOLE writer of session logs. Denies raw `Edit`/`Write`/`MultiEdit` on `codegen/logging/*.md`, and raw Bash writes (redirect/tee/in-place-stream-edit/move-into) into that path. All log mutation routes through `codegen-log init` / `section --body @-` / `section --role <role>` / `append --role <role>`.
- **`frontend-developer-guard`** — Blocks frontend developer from editing backend files.
- **`reviewer-guard`** — Blocks reviewer from editing any files (review-only role).

### Observability hooks (never block)

- **`track-subagent-edits`** — Records every file edited by a subagent to `~/.claude/post-format/<session>_<agent>.txt` for post-format targeting (interactive-session fallback).
- **`track-tool-failures`** — Records every `PostToolUseFailure` event to `~/.claude/tool-failures/<session>_<agent>.jsonl`.

### Non-interactive build gate (the loop)

Non-interactive builds are driven by the deterministic Elixir orchestration loop (`mix codegen.loop`), not SubagentStop/Stop hooks. The loop's `LoopGate` (`test_harness/lib/codegen_test_harness/loop_gate.ex`) runs the gate, and `OrchestrationLoop.run_format_step/2` runs `mix format`/`make format` explicitly after the developer and context-curator roles — these are Elixir functions, not hooks. The surviving interactive/resumable-session fallback still self-orchestrates via the outer session's prompt.

---

## Known Limitations

- `../` traversal detection is a substring check — a command like `echo "use ../path"` would be wrongly blocked for inspectors. In practice this is acceptable (inspectors should use absolute paths).
- `committer-subject-length` uses byte count (`wc -c`), not character count. Multi-byte UTF-8 subject lines may be over-blocked.
- `debug-bash-safety-guard` `curl` mutation check matches flag order `curl -X DELETE`; a command using `curl --request DELETE` or with flags before `-X` may bypass. Acceptable risk for investigation-only mode.
- `planner-guard` `mv` extraction uses `sed` anchored to start-of-command. A compound command like `true && mv /tmp/a /etc/passwd` may bypass the mv check (the `&&` makes `mv` not at position 0). Acceptable risk given planner's overall read-only intent.
- No hook currently guards against `xargs rm` or `find -exec rm`. Inspector guards cover direct `rm` usage.

---

## Testing

Each hook has a `<hook>_test.sh` companion. Run all tests:

```bash
for t in /path/to/hooks/*_test.sh; do bash "$t" || echo "FAILED: $t"; done
```

Run individual:

```bash
bash orchestrator-no-source-edit_test.sh
bash claude-inspector-bash-guard_test.sh
bash claude-debug-bash-guard_test.sh
bash planner-guard_test.sh
bash committer-subject-length_test.sh
bash session-log-writer-only_test.sh
bash track-subagent-edits_test.sh
bash track-tool-failures_test.sh
bash stop-resume_test.sh
```

Test harness pattern: each test passes JSON via stdin to the hook, captures stdout, checks for `"permissionDecision": "deny"` (deny=2) or absence (allow=0). Hooks always `exit 0`; deny is signaled via JSON stdout envelope.
