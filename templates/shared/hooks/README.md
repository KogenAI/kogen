# Claude Code Hooks — Reference

Hook scripts in this directory are installed into `.claude/hooks/` for each project via `make install` in the OCG codegen repo. They enforce role-based constraints as `PreToolUse`, `PostToolUse`, and `Stop` event hooks.

## Hook Execution Order

Claude Code fires hooks in the order declared in `.claude/settings.json`. For a given tool call, **all matching `PreToolUse` hooks run**; the first `deny` wins (remaining hooks may or may not run depending on Claude Code's implementation, but a deny is final).

Typical firing order for common roles:

### Orchestrator (top-level, no `agent_id`)

| Event          | Hooks that fire                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------- |
| `Bash`         | `orchestrator-read-discipline`, `no-cat-pipe`, `no-git-stash`, `no-python-json`, `build-worker-cwd-guard` |
| `Edit`/`Write` | `orchestrator-no-source-edit`, `session-log-section-integrity`, `build-worker-cwd-guard`                  |

### Developer (`agent_type=developer-phoenix-backend` / `developer-phoenix-frontend`)

| Event                      | Hooks that fire                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------- |
| `Bash`                     | `dev-no-ci`, `no-cat-pipe`, `no-python-json`, `no-git-stash`                          |
| `Edit`/`Write`/`MultiEdit` | `session-log-section-integrity`, `track-subagent-edits`, `env-var-sample-consistency` |
| `PostToolUse` (failure)    | `track-tool-failures`                                                                 |

### Planner (`agent_type=planner`)

| Event               | Hooks that fire                                       |
| ------------------- | ----------------------------------------------------- |
| `Bash`              | `planner-guard`, `planner-load-discipline`            |
| `Edit`              | `planner-guard` (only `codegen/logging/*.md` allowed) |
| `Write`/`MultiEdit` | `planner-guard` (always denied)                       |

### Inspector (`agent_type=inspector` / `inspector-phoenix` / `codex-inspector`)

| Event          | Hooks that fire                                                                              |
| -------------- | -------------------------------------------------------------------------------------------- |
| `Bash`         | `inspector-bash-guard` (Claude Code), `codex-inspector-bash-guard` (Codex)                  |
| `Edit`/`Write` | `inspector-write-guard`, `codex-inspector-write-guard`                                       |
| `Read`         | `inspector-read-guard`, `codex-inspector-read-guard`                                         |

### Committer (`agent_type=committer`)

| Event               | Hooks that fire                                |
| ------------------- | ---------------------------------------------- |
| `Bash` (git commit) | `committer-subject-length`, `pre-commit-guard` |

### Debug (`CLAUDE_ROLE=debug`)

| Event          | Hooks that fire                                           |
| -------------- | --------------------------------------------------------- |
| `Bash`         | `debug-bash-safety-guard`                                 |
| `Edit`/`Write` | `orchestrator-no-source-edit` (deny — debug is read-only) |

---

## Policy Summary

| Role         | Bash writes           | File writes            | Git       | Notes                       |
| ------------ | --------------------- | ---------------------- | --------- | --------------------------- |
| Orchestrator | mkdir/log only        | codegen/logging/, codegen/designs/, /tmp/ | read-only | no source edits             |
| Developer    | any (no `make ci`)    | any                    | read-only | no CI gates                 |
| Planner      | read-only + /tmp/     | codegen/logging/ only  | read-only | investigation only          |
| Inspector    | none                  | none                   | read-only | read-only investigation     |
| Committer    | `git commit/add/push` | none                   | write     | subject ≤50B                |
| Debug        | none (read-only)      | none                   | read-only | investigation, no mutations |

---

## Hook Descriptions

### Blocking hooks (deny on violation)

- **`orchestrator-no-source-edit`** — Restricts orchestrator writes per launcher. Plain orchestrator (no `CLAUDE_ROLE`, also covers `claude-build`) writes allowed under `codegen/logging/`, `codegen/designs/`, and absolute `/tmp/`. `claude-debug` / `claude-design` (`CLAUDE_ROLE=debug|design`) writes scoped to `codegen/designs/` only — for both the orchestrator and Agent-spawned helpers. Subagents under plain orchestrator bypass the hook.
- **`inspector-bash-guard`** — Blocks filesystem mutations, git writes, SQL mutations, path traversal (`../`), and redirect writes for inspector agents. Other agent types pass through.
- **`codex-inspector-bash-guard`** — Same as above for Codex environments.
- **`build-worker-cwd-guard`** — In user-app context (combobulate apps_root), prevents orchestrator from reading/writing outside the user app directory.
- **`planner-guard`** — Restricts planner to read-only bash, Edit on `codegen/logging/*.md` only, no `Write`/`MultiEdit`. Both src AND dest must be in allowed dirs for `mv`.
- **`planner-load-discipline`** — Blocks planner from loading usage_rules files directly (recipes are loaded on demand via recipes/; rules are baked into subagents).
- **`committer-subject-length`** — Blocks `git commit -m "subject"` where subject exceeds 50 bytes. Heredoc form denied (can't extract subject).
- **`dev-no-ci`** — Blocks developers from running `make ci`, `make llm`, `make llm-phoenix`. Gate commands run via `dev-gate.sh` SubagentStop hook.
- **`debug-bash-safety-guard`** — In debug sessions (`CLAUDE_ROLE=debug`), blocks: recursive rm, DB migrations, git writes, mix deps.get, seeds, destructive SQL, curl mutations (POST/PUT/PATCH/DELETE), docker mutations, systemctl/launchctl mutations, kill/pkill, package installs.
- **`session-log-section-integrity`** — Requires `## <agent_type> Section` header in `Edit`/`Write`/`MultiEdit` payloads on session log files. Exceptions: orchestrator (creates files), planner (writes `## Plan`).
- **`frontend-developer-guard`** — Blocks frontend developer from editing backend files.
- **`reviewer-guard`** — Blocks reviewer from editing any files (review-only role).

### Observability hooks (never block)

- **`track-subagent-edits`** — Records every file edited by a subagent to `~/.claude/post-format/<session>_<agent>.txt` for post-format targeting.
- **`track-tool-failures`** — Records every `PostToolUseFailure` event to `~/.claude/tool-failures/<session>_<agent>.jsonl`.
- **`post-developer-format`** — Runs `mix format` on files edited by the subagent after `SubagentStop`.

### Resume / cycle guards

- **`stop-resume`** — Auto-resumes on transient network errors (stream idle timeout, 5xx). Capped at 3 attempts. Hard failures (401, 400, 429) are not retried.
- **`stop-cycle-guard`** — Detects runaway restart loops.
- **`dev-gate`** — SubagentStop hook that fires the CI/LLM gate for developer subagents.

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
bash inspector-bash-guard_test.sh
bash debug-bash-safety-guard_test.sh
bash planner-guard_test.sh
bash committer-subject-length_test.sh
bash session-log-section-integrity_test.sh
bash track-subagent-edits_test.sh
bash track-tool-failures_test.sh
bash stop-resume_test.sh
```

Test harness pattern: each test passes JSON via stdin to the hook, captures stdout, checks for `"permissionDecision": "deny"` (deny=2) or absence (allow=0). Hooks always `exit 0`; deny is signaled via JSON stdout envelope.
