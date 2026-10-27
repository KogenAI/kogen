# Keep Claude Code Shape read-only

Slug: k12-cc-shape-readonly
Model: not applicable — three local rules in an adapter and a checkout guard; no new state machine
Acceptance:
- .kogen/intents/k12-cc-shape-readonly/acceptance.feature
- features/steps/k12_cc_shape_readonly_steps.js
- features/steps/k12_adapter_driver.go
- features/steps/k12_shape_driver.go

A Claude Code Shape or Refine session (role `shape` of the executor in `cli/executor/claudecode`, driven by `cli/shape/external.go`) must stay read-only without stopping on harmless events. Three field findings: a write-tool call whose hook did not run ended the round as `executor/protocol: hook did not run for the Edit call`; a read-only shape stopped `baseline_changed (the Git index)` because `git status` only refreshed the index stat cache; a shape left an untracked `features/steps/.keep-note` outside its Intent and the next Build stopped `environment/dirty_tree`.

## What changes

1. **Write tools denied by configuration (role `shape` only).** `roleRoundArgs` adds, immediately after `--allowedTools Bash`, the two arguments `--disallowedTools` and `Edit,Write,MultiEdit,NotebookEdit` (one comma-joined value; `--disallowedTools` is Claude Code's documented flag, the sibling of the `--allowedTools` Kogen already passes; the build and review argv and every other flag are byte-for-byte unchanged). Bash and read tools stay allowed, the permission mode stays `acceptEdits`, and the existing PreToolUse hook stays as the second line. Refine uses the same role, so it gets the same arguments.
2. **A guarded write-tool call without a hook record is feedback, not a protocol failure (role `shape` only).** In `roundRun.toolResults`, when the role is shape and a `Write`/`Edit`/`MultiEdit`/`NotebookEdit` call has no sentinel record from the hook, the adapter no longer fails with `executor/protocol`. It emits one `executor_hook` event `{"event":"executor_hook","round":<n>,"tool_use_id":<id>,"tool_name":<name>,"decision":"deny","hook":"configuration","message":"write tools are not available during Shape"}` followed by the usual `executor_tool` event with `denied: true`, and the round continues to its result and later rounds (the harness has already answered the model that the tool is unavailable; no new limit, round cap and invalid-submission rules are unchanged). Whether the checkout was really touched stays the job of the independent checkout comparison. Unchanged: for Build and Review a missing hook record is still `executor/protocol: hook did not run ...`; a hook-denied call that nevertheless ran is still `executor/protocol` in every role.
3. **Index-only refresh is not a baseline change.** `checkoutIdentity` (`cli/shape/external.go`) identifies the Git index by content: the SHA-256 of `git ls-files -s -z` (mode, object id, stage, path of every entry; an absent index is the empty listing), not of the index file bytes. A refreshed stat cache therefore compares equal; a staged path or a different object id still differs and, when no file changed, is reported as `candidate/baseline_changed` with the line `changed: (the Git index)`. HEAD, tracked-file and tracked-ignored comparisons are unchanged. In addition, for role `shape` the Claude Code child environment gets exactly one `GIT_OPTIONAL_LOCKS=0` (any inherited value is replaced), so Git does not refresh the index during the session; the build and review child environments are unchanged.
4. **Untracked files a Shape round created are removed.** Around every external round Kogen already takes the checkout identity before and after. Untracked, not ignored paths (`git ls-files --others --exclude-standard`, excluding `.kogen/local`) that are present after the round and absent from the pre-round set are *created by the round*: they are no longer reported as `baseline_changed`; Kogen removes exactly those files before anything is published, and records one event `{"event":"shape_untracked_removed","paths":[<sorted repo-relative paths>]}` in the shaping evidence (none when nothing was created). If a removal fails, the shape fails with a clear message naming the files, publishing nothing. Files that existed before the round (tracked or untracked), ignored files and `.kogen/local` are never removed or touched; a pre-existing file whose bytes or mode changed, a deleted file, a changed mode, a moved HEAD and a changed index stay `baseline_changed` / `head_moved` as today. Published Intent files are written by Kogen after the round, so they are unaffected.

Unchanged: Shape cannot change tracked files, the index or HEAD; independent detection stays; no new timeout, retry or limit; native shape routes, the Build and Review adapters and their request bytes.

## Decisions
- Pass `--disallowedTools` as one comma-joined value, shape role only. (source: request)
- Missing hook record in Shape is an `executor_hook` deny event with the fixed message plus a denied `executor_tool` event; the round continues. (source: request)
- The index is compared with `git ls-files -s -z`, which covers paths, modes, object ids and stages. (source: request)
- `GIT_OPTIONAL_LOCKS=0` is set for the shape child only. (source: request)
- Created untracked files are removed (not a failure) when removal succeeds; the evidence event is the report. (source: request)

## Source comparison
- addressed: item 1 (disallowed tools for Shape and Refine, hook kept, Bash and read tools kept) — decision 1, scenarios 1-2.
- addressed: item 2 (write call without hook is same-round feedback, not executor/protocol, no new limit) — decision 2, scenarios 3-4; Build/Review keep the protocol failure.
- addressed: item 3 (content comparison of the index, GIT_OPTIONAL_LOCKS=0, real index change still baseline_changed) — scenarios 1, 5, 6.
- addressed: item 4 (created untracked files reported and removed, pre-existing untouched, Build never inherits them) — scenarios 7-8; the Build side is checked by the GIT-1 clean rule (only the Intent's own paths may be uncommitted) applied to `git status`.
- changed deliberately: the existing case "add an untracked file" of `TestClaudeLineupShapeCheckoutGuard` expects `baseline_changed`; under item 4 a newly created untracked file is removed instead, so that case is updated (other mutations keep their expectations).
- not tested: the installed Claude Code binary itself (not runnable in the shaping environment); the flag name is the documented one and the fake `claude` of the adapter tests records the argv.
- omitted: changing the `acceptEdits` permission mode or the pre-allowed Bash of K1 note 9 (the request asks to keep Bash and does not ask for a mode change).

## Tests
- shape child argv has `--disallowedTools Edit,Write,MultiEdit,NotebookEdit` after `--allowedTools Bash`, exactly one `GIT_OPTIONAL_LOCKS=0` in its env; build argv unchanged: update `TestArgvRounds` or add a shape-role argv/env test in `cli/executor/claudecode/adapter_test.go` (unit)
- a write call without hook record in Shape is an `executor_hook` deny event and the round continues; the same in Build is still `executor/protocol`: add a Shape test beside `TestLivenessFailure` (integration)
- the index is compared by content: tests in `cli/shape` that refresh stat data (equal) and stage a path (different, `baseline_changed`): add tests in `cli/shape/lineup_shape_test.go` (integration)
- created untracked files are removed with an event, pre-existing untracked files stay, a failed removal names the files: update the "add an untracked file" case and add tests in `cli/shape/lineup_shape_test.go` (integration)
- end to end: the acceptance scenarios drive the real adapter against the fake claude and the real external Shape path (scenario)

## Feasibility
- Scratch overlay run of the Shape driver against the unchanged tree reproduces both field defects: `stat-refresh` (a `git status` after a touched tracked file rewrote the index bytes) ends `candidate/baseline_changed` with `changed: (the Git index)`; `keep-note` ends `baseline_changed` naming `features/steps/.keep-note` and leaves it in the checkout; `stage-existing` ends `baseline_changed` on the index. (probe 1: exit 0, 5 s)
- Scratch overlay run of the adapter driver against the unchanged tree: shape argv has no `--disallowedTools`, env has no `GIT_OPTIONAL_LOCKS`; a Write without hook record in a Shape session ends `executor/protocol: hook did not run for the Write call`, as does Build. (probe 2: exit 0, 3 s)
- Observer controls for the acceptance step file accept known-good and reject known-bad observations. (probe 3: exit 0 and exit 1, 0.1 s)
- evidence: {"id":"k12-observer","kind":"observer","inputs":["features/steps/k12_cc_shape_readonly_steps.js","features/steps/k12_adapter_driver.go","features/steps/k12_shape_driver.go"],"observers":["features/steps/k12_cc_shape_readonly_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k12_cc_shape_readonly_steps.js --control good","exit":0,"output":"k12 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k12_cc_shape_readonly_steps.js --control bad","exit":1,"output":"k12 observer rejected bad fixtures\n"}]}
