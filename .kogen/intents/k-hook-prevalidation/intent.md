# Continue Builds after pre-hook write rejections

Slug: k-hook-prevalidation
Model: not applicable — a per-call comparison inside the existing Claude Code stream reader; no new state machine, the Build's round and stop handling are reused unchanged.
Acceptance:
- .kogen/intents/k-hook-prevalidation/acceptance.feature
- features/steps/k_hook_prevalidation_steps.js
- features/steps/k_hook_prevalidation_driver.go

Today the Claude Code adapter stops the whole round as `executor/protocol: hook did not run for the <Tool> call "<id>"; the round was stopped` whenever a guarded call (Write, Edit, MultiEdit, NotebookEdit) has no PreToolUse sentinel record, even when Claude Code itself refused the call before the hook, for example `<tool_use_error>File has been modified since read, either by the user or by a linter. Read it again before attempting to write it.</tool_use_error>`. Nothing was written, but the Build stops as `protocol` and loses the round's progress (Build 65aed122). After this change, such a call is an ordinary failed tool call: the round continues as Claude Code continues it. A guarded call that did change its file without the hook still stops the round. Kogen tells the two apart from the stream and the file system, never from the error wording.

Rule, in `cli/executor/claudecode/stream.go` (`roundRun`):
- When the assistant `tool_use` of a guarded tool is read, record its target's file-system state. The target is the input's `file_path`, else `notebook_path`, the same keys the hook reads. A relative path is resolved against the checkout root. The state is either *absent* (the path does not exist), or a regular file, following symlinks as a write does, with its mode bits, size, modification time and the SHA-256 of its bytes. Every other case is *unobservable*: no path, a directory or other non-regular file, or any other stat/read error.
- At that call's `tool_result`, when the hook log has no pretool sentinel for it (Build and Review roles):
  - If the result has `is_error: true`, the recorded state was observable, and a fresh observation of the same target is identical (still absent, or the same mode, size, modification time and SHA-256), the call was rejected before the hook. Emit exactly one `executor_tool` event `{"event":"executor_tool","round":n,"name":<tool>,"tool_use_id":<id>,"denied":false,"rejected_before_hook":true}`, emit no `executor_hook` event for it, and continue reading the stream.
  - Otherwise stop exactly as today, with the unchanged `executor/protocol` detail `hook did not run for the <Tool> call "<id>"; the round was stopped`. That covers a success result, a changed target (content, mode, size or modification time, or created or deleted), and an unobservable target.
- Unchanged:
  - Calls with a sentinel: the `executor_hook` event, the deny-but-ran protocol stop, and the `executor_tool` event without a `rejected_before_hook` key.
  - Other `executor_tool` events: they carry no `rejected_before_hook` key.
  - Shape's configuration-deny handling of guarded calls without a sentinel.
  - The protected-baseline and HEAD detection after every round.

Boundary: the snapshot is taken when Kogen reads the `tool_use` line. A hookless write that both completes before Kogen reads that line and is reported as an error would compare equal. The post-round protected-baseline detection still catches a protected change. A later guarded call that writes without the hook still stops the round, as it does today.

No new CLI command, option, limit, timeout or retry. Document the rule in one sentence in `docs/executor-contract.md`, beside the Claude Code prevention/detection lines.

## Decisions
- A guarded call that Claude Code rejected before the hook, with nothing written, does not stop the Build as a protocol breach; the round continues as after any failed tool call (source: request)
- A guarded call that wrote without the hook still stops the round; the distinction rests on the file system and the stream, not on wording (source: request)
- No new CLI command or option, no limit/timeout/retry raise; tests use a fake executor stream and make no paid requests (source: request)

## Source comparison
- Addressed: the false protocol stop for a pre-hook rejection, using the incident's exact tool id `toolu_014z3hLJe9neZ1V8rmXgJRRi`, its Write on a file changed through Bash, and its exact `<tool_use_error>File has been modified since read...` text. These are reproduced in acceptance scenario 1, which checks that the Build continues, lands one commit and logs `rejected_before_hook`.
- Addressed: "a guarded call that did write without the hook must still stop". Scenario 2 is a hookless write reported with the same error wording and must stop with the exact unchanged detail, so wording alone cannot pass it.
- Addressed: all four guarded tools via the `file_path`/`notebook_path` target. Scenario 1 also rejects a NotebookEdit of a missing notebook (the absent state).
- Addressed: no new CLI/option/limit/timeout/retry; a fake stream (this test binary re-executed as a scripted `claude`), no paid requests.
- Superseded: the first reading of the incident (an executor version change), which the request's repro disproved (the hook fired 6/6 on Claude Code 2.1.312 and 2.1.314). Nothing is version-gated.
- Omitted: the evidence copies `kogen-macbook-runner:~/logs/krvs-run-65aed122/` and `kogen-runner:~/work.noindex/hook-repro.sh` are diagnostic provenance only, not inputs. Stream lines 253/254 and the timestamps 07:34:22.431Z/.455Z are reflected in the scripted order: tool_use, then an error tool_result with no hook.
- Conflicting: none.

## Tests
- a guarded call with no sentinel, `is_error: true` and an unchanged target (existing file and absent path) continues and emits `executor_tool` with `rejected_before_hook: true`: add tests beside `TestLivenessFailure` in `cli/executor/claudecode/adapter_test.go` that feed `roundRun` lines over temp files (integration)
- a guarded call with no sentinel and `is_error: true` whose target changed (content, or only the modification time) stops with the unchanged `hook did not run` detail: add to the same tests (integration)
- a guarded call with no sentinel, `is_error: true` and no observable target (no path) still stops: add to the same tests (integration)
- a guarded call with no sentinel and a success result still stops; Shape's configuration deny is unchanged: `TestLivenessFailure`, `TestHookLivenessIgnoresBashAndStaleLog` and the k12 scenarios (existing)
- end to end, the incident round continues and the Build lands, and a hookless write reported as an error still stops the Build as `protocol`: the acceptance scenarios drive the real Build over the real adapter and hook against a scripted fake claude (scenario)

## Feasibility
- Scratch overlay run of the submitted driver against the unchanged tree reproduces the incident. Mode `rejected-before-hook` ends exit 1, outcome `protocol`, `executor/protocol: hook did not run for the Write call "toolu_014z3hLJe9neZ1V8rmXgJRRi"; the round was stopped`, no commit. Mode `written-without-hook` ends the same way, with app.txt really written. (probe 1: exit 0, 7.5 s and 3.9 s)
- With a scratch implementation of the rule (stream.go overlay only, never in the checkout), `rejected-before-hook` lands exactly one commit with app.txt `candidate`. Its executor_tool events, in order, are Bash, the incident Write and the NotebookEdit (both `rejected_before_hook: true`), Read, and the retried Write, with one `executor_hook` pretool allow for `toolu_khp_retry`. `written-without-hook` still stops as `protocol`. The existing `./executor/claudecode` tests pass. (probe 2: exit 0, 7.7 s, 3.7 s, 13.6 s)
- The submitted feature in a `git archive HEAD` export binds every step under `--strict`. On the unchanged code: 1 passed, 1 failed (scenario 1 at "no executor round failed", 2 skipped). With the scratch rule: 2 passed. (probe 3: exit 1 then 0, 4–5 s)
- The fake waits 1 s after the `tool_use` line before its hookless write, so Kogen reads that line before the file changes, as the rule's boundary requires.
- evidence: {"id":"khp-observer","kind":"observer","inputs":["features/steps/k_hook_prevalidation_driver.go","features/steps/k_hook_prevalidation_steps.js"],"observers":["features/steps/k_hook_prevalidation_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k_hook_prevalidation_steps.js --control good","exit":0,"output":"k-hook-prevalidation observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k_hook_prevalidation_steps.js --control bad","exit":1,"output":"k-hook-prevalidation observer rejected bad fixtures\n"}]}
