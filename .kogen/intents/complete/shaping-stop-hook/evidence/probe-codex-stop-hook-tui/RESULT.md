# Probe: how a Codex TUI Stop-hook block appears in the rollout (2026-09-28)

Verdict: PROVEN for a fresh TUI turn and a `codex resume` turn. The risk it settles is Opus review finding 9
(`sq3r/opus.md`): HEAD's `integrity.py` `ordered_turn_bindings` and `driver.py` `drive` had never been checked
against a real hook block. The targets whose runs depend on this are `live-shaping-quality` and
`live-shaping-smoke`: every resumed turn they drive runs under the Codex Stop hook.

## Setup (disposable; no Kogen scope touched)

- Binary: the plain `codex` CLI on PATH, `codex-cli 0.157.1` (Kogen's managed runtime is 0.156.1; see Limits).
- Login: a private `CODEX_HOME` (`probe/stophook/home`) seeded with a **copy** of the operator's default
  `~/.codex/auth.json` (ChatGPT login; access token valid until 2026-10-06, last refresh 2026-09-26, so no
  refresh happened). `~/.codex` itself was never written; Kogen's managed runtime, login scopes and Keychain items
  were not used. The copied `auth.json` was deleted after the run.
- Cwd: a one-commit git repo `probe/stophook/repo`, pre-trusted in the private `config.toml`.
- Flags: exactly Kogen's `@common_flags` (`lib/kogen/harness/codex.ex:10-15`: `--enable hooks
  --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox`), plus `--disable apps
  --disable plugins -m gpt-6-luna -c model_reasoning_effort="low"` and one
  `-c hooks.Stop=[{hooks=[{type="command",command="sh <probe>/hook.sh",timeout=60}]}]`, the same override shape
  as the Shaper's.
- Hook (`hook.sh`): logs each Stop payload; returns `{"decision":"block","reason":"PROBE BLOCK: reply with
  exactly the word TWO …"}` when the last assistant message contains `ONE` (or `FIVE` after `FOUR`) and
  `stop_hook_active` is false; otherwise `{"continue":true}`.
- Driver: `probe.exp` (expect). Phase 1: `codex <flags> "Reply with exactly the word ONE …"`. Phase 2:
  `codex resume <flags> <session id> "Reply with exactly the word FOUR …"` (the driver's resume shape).

## Result

Stop payloads (`stop-payloads/stop-00..03.json`):

| # | turn_id | stop_hook_active | last_assistant_message | hook answer |
|---|---|---|---|---|
| 00 | `…0c3f…76e3` (fresh) | false | ONE | block |
| 01 | `…0c3f…76e3` (same) | true | TWO | allow |
| 02 | `…313e…a786` (resumed) | false | FOUR | block |
| 03 | `…313e…a786` (same) | true | FIVE | allow |

Rollout (`rollout-trimmed.jsonl`, the one rollout file; `codex resume` appended to it, `session_meta.source`
`"cli"`, `originator` `codex-tui`):

1. A block does **not** end the turn. There is no `task_complete` between the blocked stop and the continuation,
   no new `turn_context`, and no new `task_started`. The continuation runs under the **same `turn_id`**.
2. Exactly **one `task_complete` per turn**, written after the final allowed stop (lines 20 and 39), with
   `last_agent_message` = the post-block answer (`TWO`, `FIVE`).
3. The block reason enters the rollout as a `response_item` `message` with **`role: "user"`**, content text
   `<hook_prompt hook_run_id="stop:0:/&lt;session-flags&gt;/config.toml">PROBE BLOCK: …</hook_prompt>`, and
   `internal_chat_message_metadata_passthrough.turn_id` = the same turn (lines 14 and 31), followed by an
   `event_msg` `item_completed` whose `item.type` is `HookPrompt`. `hook_run_id` names the `-c` layer
   (`<session-flags>`), so a command-line Stop hook is what ran.
4. The TUI shows `• Blocked by hook └ PROBE BLOCK: …` and then the continuation.
5. A resumed turn looks like a fresh one: `task_started`, `turn_context` (its `turn_id`), the submitted
   `role: "user"` message bound to that `turn_id`, and the same block shape inside it.

## Consequences (specified in shaping-evaluation-live)

- `drive` (driver.py:883): "the first `task_complete` ends the turn" holds under the hook. The startup wait
  (`task_complete_count(roots[0]) >= 1`, `:946`) fires once, after the whole block chain.
- `integrity.ordered_turn_bindings` (integrity.py:72-114) as it is at HEAD rejects every blocked turn: the
  `<hook_prompt …>` user message trips "native user intervenes before completion" (`:105`). The fix: inside a
  bound turn, a `role: "user"` message whose text starts with `<hook_prompt ` and whose metadata `turn_id` equals
  the bound turn is part of that turn and is skipped. Any other user message, or a hook prompt bound to another
  turn, still rejects. "distinct native turn intervenes" (`:104`) needs no change: a block adds no
  `turn_context`.
- Offline replay (2026-09-28): HEAD's `integrity.ordered_turn_bindings` on `rollout-trimmed.jsonl` with the resumed
  message `Reply with exactly the word FOUR and end your turn. Do not run any tools.` raises `ValueError("native user
  intervenes before completion")` (the hook prompt at index 14). With the same-turn `<hook_prompt ` skip it returns
  `[{"user_index": 12, "turn_id": "01a0e581-313e-74f1-831f-3d117bd9a786", "completion_index": 17}]`; with both
  messages (ONE, then FOUR) it returns `[{4, 01a0e57f-0c3f-78b1-bb62-cb69eab576e3, 9}, {12, 01a0e581-…, 17}]`
  (indexes of the trimmed file).
- A hook prompt never matches a scripted answer (the match is exact text), so it cannot be bound as one.

## Part 2: one helper under the hook (`codex exec`, same scope, 2026-09-28)

Command (`probe/stophook/repo2`, private `CODEX_HOME` `home2` with a copied, then deleted, `auth.json`):
`codex exec --skip-git-repo-check <the same flags> -c hooks.Stop=[… sh hook2.sh …] --json "Probe only. Use your
spawn_agent tool exactly once to start one helper agent whose task is: reply with exactly the word HELPER-OK and
finish. Wait for it with wait_agent. Then reply with exactly the word DONE. Run no shell commands."`, with a hook
that only logs and allows (`helper-spawn/hook.sh`). Exit 0.

- Two rollouts (`helper-spawn/root-trimmed.jsonl`, `helper-spawn/helper-trimmed.jsonl`). The root: `source`
  `"exec"`, one turn, `spawn_agent` then `wait_agent`, `DONE`, one `task_complete`. The helper: **exactly one
  `session_meta`** (its own id, `source.subagent.thread_spawn.parent_thread_id` = the root, `agent_role: null`,
  `agent_path` `/root/helper`), its **own** `turn_context` only (model and effort equal to the root's:
  `gpt-6-luna` low), `HELPER-OK`, one `task_complete`. **No replay of the parent's history** for a plain
  `spawn_agent` helper.
- **One Stop payload only, the root's** (`helper-spawn/stop-payload.json`, `last_assistant_message` `DONE`). The
  helper's turn end did not fire the `-c` Stop hook.

Consequences (specified in shaping-evaluation-live): helper correlation must accept both the plain shape observed
here (one `session_meta`, own turns) and the forked shape qb recorded from 0.156.1 runs (own `session_meta`, then
the parent's `session_meta` and turns); qb's "first `session_meta` names the session, the parent's turn ids are
inherited" rule reads both correctly. A helper with `agent_role: null` runs on the root's profile, so its expected
profile is the root's, never "missing".

## Limits

- Codex 0.157.1, not the managed 0.156.1 the Shaper uses. The 0.156.1 rollouts retained in
  `test/support/shaping_audit/hook/*.jsonl` show the same event types; `live-shaping-quality` observes 0.156.1.
- `gpt-6-luna` low and one-word turns (n = 1 per phase). Tool calls between block and continuation were not
  exercised.
- A message typed into the TUI composer after a turn was not submitted by this expect script (its Enter did not
  register), so a typed follow-up turn was not observed. The driver never types follow-ups; it resumes.
- Part 2 ran `codex exec`, not the TUI, and a plain (not forked) helper. The forked-helper replay shape is qb's
  0.156.1 observation, not re-observed here. The hook still skips helper stops by `session_meta.source`
  (evidence/probe-hooks-2026-09-26.md) in case another version fires it for helpers.
