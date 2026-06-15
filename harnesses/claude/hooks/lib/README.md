# `hooks-lib.sh` — shared helper library for Claude Code hooks

Every hook script under `harnesses/claude/hooks/` sources this library to
eliminate per-script JSON parsing boilerplate and to use a single canonical
shape for deny / block decisions.

## Sourcing

```bash
source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input
```

The library expects to live at `<hooks-dir>/lib/hooks-lib.sh` relative to
the script that sources it. `install.sh` copies the `lib/` subdirectory to
`~/.claude/hooks/lib/` alongside the top-level scripts.

## `parse_input` — exported variables

After `parse_input`, these variables are set in the caller's scope (any
that are absent on stdin default to the empty string):

| Variable                 | Source field                                           | Notes                                                          |
| ------------------------ | ------------------------------------------------------ | -------------------------------------------------------------- |
| `RAW_INPUT`              | full stdin                                             | preserved verbatim for ad-hoc `jq` lookups                     |
| `TOOL_NAME`              | `.tool_name`                                           | `Bash`, `Edit`, `Write`, `Read`, `Monitor`, `apply_patch`, ... |
| `AGENT_TYPE`             | `.agent_type`                                          | empty for orchestrator-level calls                             |
| `AGENT_ID`               | `.agent_id`                                            | empty for orchestrator; non-empty inside a subagent            |
| `COMMAND`                | `.tool_input.command`                                  | for `Bash` calls                                               |
| `FILE_PATH`              | `.tool_input.file_path` // `.tool_input.notebook_path` | for `Edit`/`Write`/`Read`/`NotebookEdit`                       |
| `CWD`                    | `.cwd`                                                 | hook process working directory                                 |
| `SESSION_ID`             | `.session_id`                                          | populated on Stop / SubagentStop                               |
| `STOP_HOOK_ACTIVE`       | `.stop_hook_active`                                    | `"true"` / `"false"` (string, default `"false"`)               |
| `LAST_ASSISTANT_MESSAGE` | `.last_assistant_message`                              | populated on Stop                                              |
| `TRANSCRIPT_PATH`        | `.transcript_path`                                     | populated on Stop / SubagentStop                               |
| `PROMPT`                 | `.prompt`                                              | populated on UserPromptSubmit / SubagentStart                  |

For unusual fields (e.g. `tool_input.content` for Write, or
`tool_input.notebook_path` when the caller wants to distinguish it from
`file_path`), use `printf '%s' "$RAW_INPUT" | jq -r '<expr>'` directly.

## `deny "<reason>"` — PreToolUse decision envelope

Emits the modern Claude Code 2.x permissionDecision JSON to stdout:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "<reason>"
  }
}
```

After calling `deny`, the script must `exit 0`. The legacy `exit 2 + stderr`
convention is no longer used — every PreToolUse blocker in this directory
uses `deny`.

## `block "<reason>"` — Stop event decision envelope

Emits the Stop / SubagentStop block JSON:

```json
{ "decision": "block", "reason": "<reason>" }
```

This injects a synthetic user turn carrying `<reason>` into the next assistant
turn. Used by `stop-resume.sh` (network-error retry) and `stop-cycle-guard.sh`
(orchestrator mid-cycle stop) — **not** by PreToolUse blockers.

## `debug_log <slug> <fields…>`

Writes a timestamped line to `/tmp/<slug>-debug.log` when either:

- `CODEGEN_HOOKS_DEBUG` is set (turns on every hook's debug logging), or
- `CODEGEN_<SLUG_UPPER>_DEBUG` is set (per-hook override; `slug` is
  uppercased and hyphens become underscores).

Errors writing the log are silently ignored — this is diagnostic only.

## `hooks_realpath <path>`

Pure-bash equivalent of `python3 -c "import os; print(os.path.realpath(p))"`.
Resolves symlinks via the `cd "$(dirname …)" && pwd -P` trick, and handles
non-existent paths by walking up to the first existing parent and re-appending
the unresolved tail. Returns the absolute, symlink-free path on stdout.

## Minimal hook template

```bash
#!/bin/bash
# my-guard.sh — PreToolUse hook for <agent>
set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log my-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate the agent we care about
if [ "$AGENT_TYPE" != "<agent>" ]; then
    exit 0
fi

if [ "$TOOL_NAME" = "Write" ]; then
    deny "tool Write forbidden for <agent> — explanation"
    exit 0
fi

exit 0
```
