# Cover first-edit restore in the baseline spec

Slug: spec-baseline-guard-restores-first-edit
Model: not applicable — the change edits an acceptance spec and its fake-server fixtures; it adds no state or interacting rules
Acceptance:
- .kogen/intents/spec-baseline-guard-restores-first-edit/acceptance.feature
- features/steps/spec-baseline-guard-restores-first-edit__spec.js

The assembly scenario outline "Weakening the baseline is refused or stops the Build at once" in spec/features/05-verifying.feature still describes the old guard (exit 1 on the first shell edit of an approved acceptance file). The product now restores the first such shell edit in an attempt to the approved bytes and the Build continues; the second such edit in the same attempt is refused with class candidate/baseline_changed (exit 1, nothing committed) and the text "the Build changed acceptance files: <paths>; nothing was committed", where <paths> is the changed path. This Intent makes the spec state that behaviour for the same three protected targets: the Intent's acceptance.feature, the step file features/steps/is_even_steps.js, and .style.cfg (protected through the protect setting).

The single old outline is removed and replaced by two outlines, each with the three examples, both keeping the tags VER-8, VER-12 and model:build:
- a restore outline (script build-runs-command): the Build is told the path and the phrase "acceptance files cannot be edited", the file equals the approved bytes afterwards, the approved acceptance.feature is unchanged, and the run exits 0;
- a refusal outline (a new script that issues the same shell command twice in one attempt): exit 1, stdout contains "candidate/baseline_changed: the Build changed acceptance files: <path>; nothing was committed", no request was sent after the last shell command, and HEAD is unchanged.

Scope: spec/features/05-verifying.feature and files under test/acceptance. No existing fake ChatGPT script issues two shell edits of the same file in one attempt (build-runs-command issues one), so the refusal outline plays a new fake ChatGPT script; no existing script changes behaviour. The step "no request was sent after that command" in test/acceptance/support/handlers.js refers to the last shell call of the Build instead of the first, which is identical for every scenario with a single shell call. Other baseline refusal scenarios (hooks, fixers, passes, commit) and every other scenario stay unchanged. spec/features/STEPS.md, every other document, kogen-build, the release scripts and every setting are not edited; no flag, setting or environment variable is added.

## Decisions
- The restore outline and the refusal outline are separate scenario outlines, each with the same three examples (acceptance.feature, is_even_steps.js, .style.cfg), tagged @VER-8 @VER-12 @model:build like the outline they replace. (evidence: spec/features/05-verifying.feature) (source: request)
- Because no existing script issues two shell edits in one attempt, the second-edit scenarios play one new fake ChatGPT script beside build-runs-command; no existing script changes behaviour. (evidence: test/acceptance/support/fake-servers.js) (source: request)
- The step "no request was sent after that command" looks at the last Build shell call, so it checks the second edit in the refusal outline; scenarios with one shell call behave as before. (evidence: test/acceptance/support/handlers.js) (source: request)
- The restore message is asserted with existing steps: the tool result for the first shell call contains the path and the phrase "acceptance files cannot be edited"; no step vocabulary in spec/features/STEPS.md is added. (evidence: spec/features/STEPS.md) (source: request)
- Scenario outline names are chosen by this Intent, since the request leaves them open. (assumption: the names "A first shell edit of a protected file is restored and the Build goes on" and "A second shell edit of a protected file in one attempt is refused" are acceptable) (source: request)
- The new script's name and where it is defined are left to the Build; the acceptance reads the name from the refusal outline and checks only that it differs from build-runs-command, that a file under test/acceptance/support names it, and that build-runs-command keeps its code. (assumption: a suitable layout is a script build-runs-command-twice in its own file test/acceptance/support/build-runs-command-twice.js with a short dispatch case in fake-servers.js, but this is a suggestion and is not asserted) (source: request)
- The exit-1 refusal assertion with the exact text "candidate/baseline_changed: the Build changed acceptance files: <path>; nothing was committed" exists for all three paths; no scenario is removed, skipped or weakened. (source: request)
- Replace the single outline with a restore outline and a refusal outline, adding one fake-server script case for the second edit and pointing the 'no request was sent after that command' step at the last shell call. (decision: D1, round 1) (constraint: do not edit STEPS.md or docs) (constraint: existing scripts keep behaviour) (evidence: spec/features/05-verifying.feature; test/acceptance/support/fake-servers.js; test/acceptance/support/handlers.js; spec/features/STEPS.md) (assumption: The real kogen-build restore message text was not found in this repository, so the restore outline's assertion of the path and phrase 'acceptance files cannot be edited' rests on the request. The real scenarios were not run here because they need a packaged release; the Intent's acceptance checks their structure only.) (source: request)
- The acceptance step "every other scenario of the spec file is unchanged from HEAD" must hold both before the Build and in a tree whose HEAD already contains the two new outlines, so it drops the old outline and the two new outlines from the working-tree list and from the HEAD list alike before comparing the rest. (evidence: features/steps/spec-baseline-guard-restores-first-edit__spec.js) (source: request)

## Source comparison
- Old outline "Weakening the baseline is refused or stops the Build at once" (spec/features/05-verifying.feature, examples at lines 85-87): superseded by the restore outline and the refusal outline; its three paths and the exact refusal text are carried into the refusal outline.
- Scenarios for hooks, fixers, passes and commit baseline refusals: unchanged.
- spec/features/STEPS.md and all documentation: omitted by request; not edited.
- Build 8bb42260 correction (protected-baseline report, step at features/steps/spec-baseline-guard-restores-first-edit__spec.js lines 85-92): addressed. The unchanged-scenarios step filtered the new outlines only from the working-tree list, so it failed in a tree whose HEAD already holds them; it now applies one filter (old outline by name, new outlines by marker text) to both lists.
- Contract check on the fixture mechanism: addressed. The fixed fixture file name, the three-line dispatch and the own-file requirement are no longer prose or asserted; the refusal scenario now requires only a script other than build-runs-command that the fake server names, with build-runs-command unchanged.

## Tests
- A first shell edit of each protected path is restored and the Build lands: the restore outline in spec/features/05-verifying.feature, checked structurally by this Intent's acceptance (scenario)
- A second shell edit of each protected path in one attempt is refused with the exact text and nothing committed: the refusal outline and its new fake ChatGPT script (scenario)
- The old outline is removed and all other scenarios of the file are unchanged: this Intent's acceptance compares them with HEAD, with or without the candidate outlines in HEAD (scenario)

## Feasibility
- none
