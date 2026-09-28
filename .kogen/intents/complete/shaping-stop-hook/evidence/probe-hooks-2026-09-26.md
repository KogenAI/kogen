# Probe: Stop hooks on Claude and Codex helper identity (2026-09-26, revision 13)

## Claude Stop hook blocks once and continues: PASS
Managed claude 2.1.281 `-p --model claude-sonnet-5 --effort low --settings
settings.json` in a disposable git repo. The Stop hook (`hook.sh`) logged its
payload and returned `{"decision":"block","reason":"Write the word AUDITED to
audited.txt, then stop."}` once. Observed: two Stop payloads with the same
`session_id`, `stop_hook_active` false then true; `audited.txt` contained
`AUDITED`; exit 0 in 12 s. This is the mechanism `claude-shaping-under-hook`
relies on. (Side observation: the `-p` session mentioned a claude.ai account
connector needing authorization, so account connectors reach `-p` sessions
that do not pass a strict MCP configuration.)

## Codex: telling helper stops from the root: PASS (by rollout metadata)
- Run 1 was invalid: `codex exec` waited on stdin until the 240 s kill.
- Runs 2 and 3 (`codex exec --enable hooks --dangerously-bypass-hook-trust`
  with a `-c hooks.Stop=…` logging hook, luna low then sol low): one Stop
  payload for the root (`codex-root-stop.json`): keys `session_id`,
  `turn_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`,
  `permission_mode`, `stop_hook_active`, `last_assistant_message`. The model
  called `wait` but never `spawn_agent`, so whether helpers fire the hook was
  not observed in exec.
- Real rollouts from the case-fit prototype (interactive Codex Shaper, three
  helpers) show the discriminator in each rollout's first line
  (`session_meta.payload.source`): the root is `"cli"` (or `"exec"`), and
  each helper is `{"subagent": {"thread_spawn": {"parent_thread_id":
  "<root>", "depth": 1, "agent_path": "/root/codebase_reader", ...}}}`.
- Solution chosen: the hook reads the first line of the payload's
  `transcript_path` and allows, without auditing, any stop whose source is
  a subagent. Whether helpers fire the hook then does not matter.

Limitations: the helper-fires-hook question itself stays unobserved; the
discriminator is from 0.156.1 rollouts.
