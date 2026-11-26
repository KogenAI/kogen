# Correct canonical protected-edit advice

Slug: spec-protected-edit-listed-file-advice
Model: not applicable — two literal substitutions, with no state or runtime behavior change
Acceptance:
- .kogen/intents/spec-protected-edit-listed-file-advice/acceptance.feature
- features/steps/spec-protected-edit-listed-file-advice__steps.js

Correct exactly two stale Next messages. In `spec/features/02-shaping.feature`, in “A required protected edit is reported without creating an Intent or approval”, replace only the text inside the existing `And stdout contains` Next assertion. Make exactly the same literal substitution inside the backticks in SHP-4 of `spec/prose/02-shaping.md`. Replace `Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override.` with the exact advice supplied from landed Shaping `aac5e7292db227252c0bf2157e4d565ecd4a56a1`:

`Next: revise the request so it needs no edit to the files listed above, or review and commit those files outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override.`

Independent review must inspect the production diff and verify those two literal substitutions and no other production edits. Keep every other runtime scenario step and tag, including `@SHP-3 @SHP-4 @SHP-7`, `.style.cfg`, exit 1, the exact tool list `read_file, view_image, list_files, search_text, probe, documentation, propose_files, check_package, submit`, no Intent or approval, and one provider request. Preserve the `shape-protected-conflict` fake submit fixture, all protected-edit negative controls, CLI, pins, configuration, release workflow and suite selectors.

The request reports that this exact correction passed 271 non-live scenarios (3827 steps) on EU2 against retained candidate `cd204439`, and that the corrected full original protected-edit scenario passed all 22 steps. Those are historical results, not qualification of this Build or grounds to reuse old green. The old public runtime still emits obsolete advice; do not accept both messages or change or skip the runtime assertion to accommodate it. Preserve attempt `e564f010` evidence in supported custody, use normal public-runtime admission, and leave full qualification of the new exact assembled release after landing to Release/Recovery. Do not move unlanded implementation or substitute a prior candidate for current verification.

## Decisions
- Exactly two literal substitutions only; keep every other runtime scenario step and tag and preserve the fake submit fixture and all protected-edit negative controls. (evidence: spec/features/02-shaping.feature; spec/prose/02-shaping.md; test/acceptance/support/fake-servers.js) (source: request)
- Use one native acceptance scenario with two read-only assertions on the scratch checkout; no historical Git object, checkout comparison or hash, duplicate fixture of the full release scenario, or release suite execution from a step. (evidence: .kogen/project.yaml) (source: request)
- Keep CLI, pins, configuration, release workflow, suite selectors and ordinary configured checks unchanged. Preserve attempt e564f010 evidence; use supported custody and normal public-runtime admission. (source: request)

## Source comparison
Addressed: the request’s exact landed Shaping literal replaces the obsolete configuration-file advice in the named runtime assertion and SHP-4 only. The two bindings in `acceptance.feature` read those source locations directly, with a per-location stale-message control in `controls.json`. Everything else in the runtime scenario, its tags, fixture and negative controls is preserved by the two-substitution review boundary, not by a fixture copy or checkout comparison. The request’s EU2 and 22-step results are retained as historical evidence only; the ordinary checks stay in Build and full exact-assembly qualification stays with Release/Recovery after landing. No alternate Next literal, override, suite selector change, or runtime change is in scope.

## Tests
- The named scenario contains exactly the new stdout Next step: first native assertion, with the feature-only stale control (regression)
- SHP-4 contains the exact new Next literal: second native assertion, with the prose-only stale control (regression)
- Ordinary spec validation and configured checks remain enabled: existing project checks (existing)
- The unchanged full runtime scenario apart from its corrected literal still checks the blocked response: full release qualification on the exact new assembled release after landing (existing)

## Feasibility
- Generated the correct and two independently stale scratch overlays from the current sources; each wrong overlay restores only its own old Next literal (probe 1: exit 0, 0.1 s).
- Regenerated with unified diff context, applied both corrections, confirmed their exact bytes and checked that each stale variant applies (probe 2: exit 0, 0.1 s). No external dependency or provider probe is required.
