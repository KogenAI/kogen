# Probe: how a turn ends when Stop answers `verification already terminal`

23 September 2026, root Shaping probe, run from this Shaping session on the
managed runtimes and the Kogen shared login scopes. Each harness ran in its own
disposable Git repository under the session scratchpad. The raw streams are not
retained because they contain model reasoning. The retained files are
`stop-terminal-probe/claude-stop.sh`, `claude-settings.json`, `codex-hooks.json`,
`claude-turns.txt` and `codex-turns.txt`, which hold the result/final-message
fields only.

**Question.** When a report-only Developer turn runs after the attempt's Stop
verification has already passed, `.codex/hooks/stop_runner.py` answers
`{"continue":false,"stopReason":"verification already terminal: passed"}`.
Does each harness still report that turn as a normal completed turn with its
final message, both with and without an enforced output schema?

**Hook.** The first Stop in a session prints `{"continue":true}`, standing in for
a passing verification. Every later Stop prints exactly the terminal answer
above. A counter file records how many times Stop fired.

## Claude Code 2.1.280 (`claude-haiku-4-5-20251001`, `-p --output-format stream-json --verbose`, same flags Kogen uses minus agents/disallowedTools)

| Turn | Mode | Stop answer | Result event |
| --- | --- | --- | --- |
| 1 | `--session-id`, plain | continue:true | `success`, `is_error:false`, `terminal_reason: completed`, `result: {"turn":1}` |
| 2 | `--resume`, plain | **continue:false terminal** | `success`, `is_error:false`, **`terminal_reason: stop_hook_prevented`**, `result: {"turn":2}` (message intact), exit 0 |
| 3 | `--resume --json-schema` | **continue:false terminal** | model answered in text first; Stop fired; `success`, `terminal_reason: stop_hook_prevented`, **`result: ""`, `structured_output: null`** |
| 4 (control) | `--resume --json-schema` | continue:true | model answered in text, then Claude Code drove it to call StructuredOutput; `structured_output: {"turn":4}`, `terminal_reason: completed` |
| 5 | `--resume --json-schema`, told to call StructuredOutput directly | continue:false terminal (fired, ignored) | `structured_output: {"turn":5}`, `terminal_reason: completed` |

Findings:

- A plain resumed Developer turn that Stop ends with the terminal answer is
  reported as a successful turn. Its final assistant message is intact in
  `result`, and exit status is 0. Kogen's current `parse_stream/4`
  (`lib/kogen/harness/claude.ex:383`) accepts it, because it only requires
  `subtype == "success"` and `is_error != true`. A correct report-only
  correction therefore is not mistaken for a failed turn. The only new marker is
  `terminal_reason: "stop_hook_prevented"`.
- Direction 2 (`--json-schema` on a report-only turn) is **not reliable** while
  Stop answers `continue:false`. If the model writes text before calling
  StructuredOutput, the terminal Stop cuts off Claude Code's structured-output
  nudge and the result is empty (turn 3). If it calls StructuredOutput first,
  the output survives (turn 5). Enforced structure would therefore depend on
  model behavior, or it would need Stop to answer differently for report-only
  turns. That is an extra Stop-contract change.

## Codex 0.154.0 (`gpt-5.6-luna`, low; `exec --json --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox`)

| Turn | Mode | Stop answer | Observed |
| --- | --- | --- | --- |
| t1 | `exec`, plain | continue:true | `turn.completed`; last message `{"turn":1}` |
| t2 | `exec resume`, plain | **continue:false terminal** | `turn.completed`; `agent_message` and `--output-last-message` both `{"turn":2}`; exit 0 |
| t3 | `exec resume --output-schema` | **continue:false terminal** | `turn.completed`; `--output-last-message` `{"turn":3}`; exit 0 |

Codex does not expose the Stop outcome in its JSON events. A report-only turn
ends like any other completed turn, and the schema-constrained last-message file
is written.

## Consequences for this Intent

- Report-only correction turns (direction 5) work on both harnesses **without
  any Stop-runner change**. Stop keeps answering `already terminal: passed`, and
  nothing is re-run. The controller must detect any Candidate change itself, by
  comparing `Kogen.Git.candidate_id/0` before and after the turn.
- `terminal_reason: stop_hook_prevented` is a normal, successful ending for a
  Claude correction turn. It must not be classified as a harness failure.
- Direction 2 is left out. On Claude Code it would also need Stop to answer
  `continue:true` for report-only turns, and even then structured output is only
  a shape check.

## Limits

One host (macOS arm64), one small model per harness and a few requests. The
Build's Developer runs on `claude-opus-5-5`. Since the Claude result was
`success` with the message intact regardless of model, the finding about the
plain turn does not depend on model behavior. The Build proves the controller
side offline with fake harnesses that reproduce these observed result shapes.
