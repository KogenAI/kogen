# Deliver frozen context to external Build

Slug: k-context-external
Model: not applicable — this fixes diagnostic input wiring, not a state machine
Acceptance:
- .kogen/intents/k-context-external/acceptance.feature
- features/steps/k_context_external_steps.js

Deliver the frozen `build --context` diagnostic to the external builder's first prompt and to either independent reviewer, regardless of builder selection. Replace review's dependence on the native builder working window with the frozen diagnostic capture. Preserve the exact existing diagnostic label, source path, SHA-256, text and authority disclaimer produced by `Diagnostic.message()`. Keep diagnostics separate from authority and never import old work or reuse old green evidence.

Use the existing Build/executor interfaces; no CLI changes, new settings, raised limits, timeouts or retries. Native builder requests with and without context must retain their existing bytes; no-context Build and review requests must remain byte-identical. Native review diagnostic bytes remain unchanged. Keep all configured checks. All test processes use disposable temporary repositories; no process-name/pattern killing, unrelated process stops or synthetic CPU load.

## Decisions
- Frozen caller diagnostics are lower-authority data for every builder and reviewer, not approval or a plan. (source: request)
- Test external builders with a fake executor and both native and external reviewers, including recovery-generated context. (source: request)

## Source comparison
- Addressed: request What to change and audit P2 #3 / LOOP-2 / REV-2: deliver the existing labelled frozen diagnostic to the external first prompt and obtain review diagnostics independently of native working windows; covered by the regression matrix below.
- Addressed: Must stay and Acceptance: preserve native bytes, absent-context bytes, CLI, limits, retry/timeout policy and configured checks; covered by compatibility regression below and normal configured gates.
- Addressed: supplied recovery example `kogen intent build <slug> --context <archive>/context.md`: test recovery handoff contents as diagnostic input, including archived failure cause and references, not production/approval import. Preserve Refine, new exact approval and fresh Build prerequisites; recovery itself is not changed.
- Addressed: Host safety: only temporary fixtures and owned child processes.
- Addressed with repository limitation: remove item 3 from K-EXEC-KILL's scope once landed. Repository search found no K-EXEC-KILL text; update an existing roadmap record if present at implementation, otherwise report the external tracking follow-up at delivery, without inventing a new roadmap file or claiming an external tracker was changed.
- Superseded: current native-only delivery and review extraction from `WorkingContext["build"].Mandatory[1:]` are bug evidence, not desired behavior. No other audit items or K-EXEC-KILL scope are included.

## Tests
- External first-prompt delivery: add `TestContextExternalFirstPrompt` in cli/build using the real Build entry point, temporary Git and existing fake executor; assert the exact existing labelled message reaches the first prompt, not merely private capture or a later round (regression)
- Every builder/reviewer combination receives the frozen diagnostic: add `TestContextExternalReviewMatrix` using real Build, existing fake executors/local provider and normal verification/review; cover native/native, native/external, external/native and external/external, asserting exact labelled diagnostic bytes in review, without builder replay; include changed/deleted original source and recovery-generated context.md contents with failure cause/archive references (integration)
- Native and omitted-context compatibility: add `TestContextExternalNativeBytes` comparing complete native opening requests against pre-fix expected bytes with and without diagnostic, and no-context requests for all executor combinations; normalize only nondeterministic run/repository identities, not prompt content. Keep existing diagnostic capture, review reset and recovery tests (regression)
- Existing native capture remains useful: run `TestBuildWithDiagnosticDataKeepsItPrivatelyAndSendsItAfterTheOpeningMessage` unchanged (existing)

The new named tests belong to editable Go test files, not Acceptance protection. Their bodies must exercise the outcomes above, not merely report their names or inspect production source. The acceptance bridge requires each exact test to run and pass through `go test -json ./build`; a missing or skipped test fails. Confirm the external regression reproduces the pre-fix loss. First-prompt evidence must include the actual executor prompt construction (extend the Claude Code fake-process fixture if the Build fake only observes Task fields).

## Feasibility
- Existing native diagnostic integration command `cd cli && go test -json ./build -run '^TestBuildWithDiagnosticDataKeepsItPrivatelyAndSendsItAfterTheOpeningMessage$' -count=1` passed (probe: exit 0, 6.9 s). No external protocol changes or live provider research are needed for this local wiring fix.
- evidence: {"id":"named-observer","kind":"observer","inputs":["features/steps/k_context_external_steps.js"],"observers":["features/steps/k_context_external_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_context_external_steps.js --control good","exit":0,"output":""},{"name":"bad","command":"node features/steps/k_context_external_steps.js --control bad","exit":1,"output":"TestContextExternalFirstPrompt: go test -json ./build: absent, skipped, failed or zero runs\n"}]}
