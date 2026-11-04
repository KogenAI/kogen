# Describe the per-Intent step namespace in spec

Slug: k-spec-shape-step-namespace
Model: not applicable — a documentation-only change to the specification text; no state or executable behavior changes
Acceptance:
- .kogen/intents/k-spec-shape-step-namespace/acceptance.feature
- features/steps/k-spec-shape-step-namespace__spec_text.js

Kogen's specification must describe what pinned kogen-shaping (commit 3e17221, Intent k-step-file-collision) now enforces when Shape writes a new Intent. A shaped step file lives directly under the steps directory as `<slug>__<suffix>.js` with a nonempty suffix. Every step sentence and definition starts with `<slug>: `. A generic name such as `features/steps/is_even_steps.js` is an invalid submission.

State of this checkout (HEAD f8c3fb5, component pins of 41d7005, which already include the rule): commit 96b7438 (Kogen-Intent k-fullscan-assembly) already moved the executable parts to the namespace. Those parts are the fake ChatGPT shaper (`intentFiles` and `counterFiles` in `test/acceptance/support/fake-servers.js`, which write `features/steps/is-even__steps.js` / `features/steps/counter__steps.js` with `is-even: ` / `counter: ` sentences), the fake Claude Code shaper (`structured_intent` reuses `intentFiles`), the py-calc fixture `features/steps/is-even__existing.js`, and the scenario expectations in `spec/features/02-shaping.feature`, `08-chatgpt.feature` and `claude-code-full-lineup.feature`. During shaping, an external read-only session ran the 32 locations named in the request (01-project-setup.feature:290; 02-shaping.feature:22,40,58,153,199,257,304,379,380,383,395,423,439,463,476,486,499,510,548,560; 08-chatgpt.feature:146,160,208,209,210,234,251; claude-code-full-lineup.feature:14,44,260,437) against `dist/kogen-f8c3fb5e-darwin-arm64.tar.gz`. They selected 30 scenarios: 30 passed, 462 steps passed, 202 s wall time with 8 workers. This is an observation, not a Kogen probe record. Do not edit those fixtures, scenarios or the harness again.

What remains is the specification text. It still describes generic step files: `spec/prose/02-shaping.md` and `spec/features/STEPS.md`. This Intent replaces that text, exactly as below. Fixtures, scenarios and prose for already-approved/legacy Intents that do not go through new shaping keep their old names. Do not touch the `is-even` fixture Intent and its `features/steps/is_even_steps.js`, the 03-approval, 04-building, 05-verifying and 07-committing expectations, `spec/prose/03-approval-and-build-start.md`, the STEPS.md "Intent `is-even`" row, or the refine scripts' `is_even_steps.js` rewrite. Do not add commands, flags, options, timeouts or retries. Do not edit components. Do not edit `cli/go.mod`, `cli/go.sum` or anything under protection. The component rule gets no compatibility escape. `(cd spec && sh check.sh)` must stay green.

Required edits in `spec/prose/02-shaping.md`:

1. In `## The Intent`, replace the sentence `Step definitions live in step files under `commands.acceptance.steps_dir`: existing files that are reused or edited, or new ones.` with exactly:
   Step definitions live in the Intent's own step files directly under `commands.acceptance.steps_dir`, each named `<slug>__<suffix>.js` with a nonempty suffix (for `is-even`, `features/steps/is-even__steps.js`). Every step sentence of its `acceptance.feature` and every step definition in those files starts with the literal prefix `<slug>: ` (for example `Given is-even: the input is 4`); its scenarios use no other Intent's step files or bindings. Packages shaped before this rule, such as already approved or landed Intents, keep their step file names and need not be renamed.
2. In the Intent example block, the `Acceptance:` list becomes `- .kogen/intents/is-even/acceptance.feature` followed by `- features/steps/is-even__steps.js`.
3. In SHP-4, replace the sentence that begins `Files may only be the Intent's own files and step files under `steps_dir`, new or existing:` (through `(VER-1).`) with exactly:
   Files may only be the Intent's own files and step files named `<steps_dir>/<slug>__<suffix>.js` (nonempty suffix), new or existing: shaping may prepare edits to an existing step file of that name, which the caller reviews with the Intent before approval and which is then fixed for the Build (VER-1). Any other path under `steps_dir`, such as a generic `features/steps/is_even_steps.js`, is an invalid submission with the problem `<path>: new step files must be named <steps_dir>/<slug>__<suffix>.js (nonempty suffix); prefix step sentences and definitions with <slug>: `. Before readiness, the step self-check reports `step sentence must start with <slug>: `, `definition must start with <slug>: ` or `binding comes from a step file outside this Intent: <file>` for a step that breaks this namespace, and nothing is published.
4. In the SHP-8 ready output example, the line becomes `Step files: features/steps/is-even__steps.js (new)`.

Required edits in `spec/features/STEPS.md`:

5. In the `py-calc` project fixture row, after `` `features/steps/calc_steps.js` (existing step definitions running `python3 -c`)`` insert `, `features/steps/is-even__existing.js` (an existing step file in the `is-even` namespace that shaping may edit)`.
6. In the `## Fake ChatGPT server` section, before its script table, add the paragraph: Every script that submits a new `is-even` package names its step file `features/steps/is-even__steps.js` and starts every step sentence and definition with `is-even: `; `shape-failing-invariant` submits `counter` with `features/steps/counter__steps.js` and the prefix `counter: `. Approved fixture Intents shaped before this rule keep their step file names.
7. The `shape-edits-existing-step-file` row becomes: submits `is-even` with an edit to the existing `features/steps/is-even__existing.js`.

After this lands, any further cause that this refusal was masking in the 32 scenarios (for example the Decision evidence rule of 993411d, which requires that cited files were read or listed this Shaping) is a follow-up. It is not guessed here.

## Decisions
- New Intent step files are `<slug>__<suffix>.js` with `<slug>: `-prefixed step sentences and definitions; the spec and fake shaper fixtures describe that, and legacy approved fixtures keep their names. (source: request)
- Behavior of the existing scenarios is unchanged; no new commands, flags or raised timeouts; components, `cli/go.mod` and `cli/go.sum` are not edited; the rule gets no compatibility escape. (source: request)

## Source comparison
- Addressed (already on this checkout via 96b7438): fake shaper fixtures (`intentFiles`, `counterFiles`, fake Claude `structured_intent`) submit `features/steps/is-even__steps.js` / `features/steps/counter__steps.js` with `is-even: ` / `counter: ` sentences; scenario path expectations (02-shaping.feature:58, :153, :257, :486 and the Outline/question/undefined-step texts) name the namespaced files. External observation: the 32 named locations selected 30 scenarios, all passed (462 steps, 202 s, 8 workers). Kept as existing coverage in Tests; not re-edited.
- Addressed by this Intent: "the acceptance spec ... must describe the new behaviour" -> spec/prose/02-shaping.md edits 1-4 and spec/features/STEPS.md edits 5-7; acceptance.feature scenarios 1-3.
- Addressed: legacy fixtures for approved Intents may keep old names -> the `is-even` fixture Intent, its `features/steps/is_even_steps.js`, 03/04/05/07 feature expectations, 03 prose card and refine scripts stay unchanged.
- Addressed constraints: no new commands/flags, no raised timeout, `cli/go.mod`/`cli/go.sum` and components untouched, no compatibility escape in the rule.
- Conflicting/superseded: the request's Base names local commit 900a6a8 (repin-prompt-move), where the fixtures were still generic. This checkout is HEAD f8c3fb5 on main's lineage, which already contains 96b7438 and pins kogen-shaping f04edcea9896, which enforces the rule. Its failing-scenario list and transcripts describe 900a6a8, not this checkout. Approval records this HEAD, so the Build starts here.
- Omitted deliberately: the follow-up the request defers (other causes the refusal masked, e.g. the 993411d Decision evidence rule); the stale SHP-6 question example wording, which is unrelated to the step namespace.
- Retry cause ("no candidate/intent/shape line in the log") concerns the delivery harness's previous attempt and is not a product requirement.

## Tests
- The shaping chapter states the `<slug>__<suffix>.js` naming, the `<slug>: ` prefix, the invalid-submission problem text and the self-check ownership details, and drops the reuse-any-step-file wording: acceptance.feature scenario "The shaping chapter states the per-Intent step-file namespace and its refusals" (scenario)
- The shaping chapter's Intent example and ready output name `features/steps/is-even__steps.js`: acceptance.feature scenario "The shaping chapter's examples name the namespaced step file" (scenario)
- STEPS.md describes the namespaced shaper fixtures and the edited `features/steps/is-even__existing.js`: acceptance.feature scenario "The step vocabulary describes the namespaced shaper fixtures" (scenario)
- The specification stays internally consistent: unchanged `(cd spec && sh check.sh)` configured check (existing)
- The 32 named scenarios keep passing with the namespaced fixtures: unchanged spec/features scenarios listed above, run by the test/acceptance suite (existing)

## Feasibility
- none
