# Native pre-execution probe

Observed 2026-09-09 using installed `codex-cli 0.153.4`, model
`gpt-5.6-terra`, effort `high` (the configured Developer profile).

An isolated temporary Git repository contained a harmless `make check` target
whose only action was `touch gate-ran`. A project PreToolUse hook matched `Bash`
and returned `hookSpecificOutput.permissionDecision: deny`. Codex was launched
with `--enable hooks --dangerously-bypass-hook-trust
--dangerously-bypass-approvals-and-sandbox --json`. The probe prompt requested
exactly one `make check` attempt and instructed no retry or bypass.

Observed hook input: `hook_event_name: PreToolUse`, `tool_name: Bash`,
`tool_input.command: make check`, `permission_mode: bypassPermissions`.
The model reported the hook rejection, the turn completed, and `gate-ran` did
not exist. This proves pre-dispatch denial under the current bypass flags.
It does not test selective classification, helper inheritance, resume behavior,
policy failure, or arbitrary indirect shell execution.

Sources retained: probe hook/config/Makefile and model event output alongside
this note. The fixture hook intentionally denies all Bash calls; it is probe
material, not a production implementation.

Official reference: https://learn.chatgpt.com/docs/hooks (retrieved 2026-09-09).
The documentation specifies PreToolUse denial and notes that write_stdin does
not trigger a new PreToolUse event and some specialized tools bypass this path.

Repository findings at the shaped head: developer.md permits early non-check
execution; build.ex deduplicates declared targets, settles Stop evidence, runs
non-check gates sequentially/fail-fast, and reruns after outer rework. See
lib/kogen/build.ex lines 176-255 and 333-365. Existing tests lack comprehensive
owner/count assertions and Developer-command prevention.
