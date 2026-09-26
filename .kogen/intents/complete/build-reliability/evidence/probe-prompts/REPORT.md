# role-prompt-tune-up: investigation (main @ 7ed41f66)

## 1. Prompt structure

`priv/kogen/prompts/developer.md`: "## Your job" (33-37) already says
"Implement this Approved Intent fully, so that every scenario in
`scenarios.yaml` is genuinely satisfied — not just plausible-looking" and
"Read each scenario's `given`/`when`/`then` and `wrong_result` carefully" —
scenarios are rendered as prose guidance, not literally interpolated (no
`{{scenarios_text}}` placeholder used in the file read by the controller;
the Developer is told to read `scenarios.yaml` itself from the Approved
package path, `{{approved_path}}`). A "done when" line fits naturally at the
end of "## Your job" (44) or as a new subsection before "## Verification
after each turn" (50). A pre-stop self-review step fits right before
"## Final Developer notes" (149) or as a new step inside it, since that's
literally the last thing before turn-end output.

Turn-end output ("## Final Developer notes", 149-186): free prose only —
"End your turn with a short free-prose final message (your notes)"
(165-167); no JSON handoff ("Do not write a JSON handoff", 161). Required
content: per-scenario done/unfinished statement (169-171), contract
objections (172-178), and answers to open Reviewer findings (179-181).
There's no "checklist" or structured section today — self-review would add
prose, not a new schema.

`reviewer.md`: findings today are `{"scenario_ids", "reason", "evidence"}`
(207-213) — no "what was/wasn't checked" field. "Mandatory completeness
step" (230-245) already forces the Reviewer to double-check coverage before
returning; a "checked/not-checked" note would extend `reason` text or a new
field (see #3).

`execution-policy.md` is shared boilerplate (delegation policy) injected via
`{{execution_policy}}`; not directly relevant to done-when/self-review/
checked-text, except that it already models "concise... uncertainty,
failures" reporting (35-36) — same spirit as "what wasn't checked."

## 2. Rendering and tests

`lib/kogen/build.ex`:
- `render_developer_prompt/5` (2210-2279): reads
  `roots.control <> "priv/kogen/prompts/developer.md"`, substitutes
  `{{intent_title}}`, `{{intent_id}}`, `{{approved_path}}`,
  `{{may_change_guarded_paths}}`, `{{verification_ownership}}`,
  `{{readiness_commands}}`, `{{execution_policy}}`. No scenario text is
  interpolated — `_scenarios_text` param is ignored (2221); scenarios reach
  the Developer only via the Approved package path it must read itself.
- `render_reviewer_prompt/4` (2312-2324): substitutes `{{intent_title}}`,
  `{{intent_id}}`, `{{approved_path}}`, `{{candidate_id}}`,
  `{{execution_policy}}`. Same file for both harnesses — no harness
  branching in either render function.

Offline tests asserting prompt content: `test/kogen/harness_contract_test.exs`
line 80 "the Developer and Reviewer prompts keep main's full placeholder set"
(84-108) enumerates both placeholder lists and asserts every placeholder is
present, then substitutes and re-checks rendered output; the same
`priv/kogen/prompts/developer.md`/`reviewer.md` files are copied verbatim
into fixture worktrees for both `claude` and `codex` harness runs (lines
80-82 read from the real repo; 645-647 copy the identical files into a
per-harness fixture dest) — i.e. harness-neutral by construction/test today.
`test/kogen/readme_guidance_test.exs` (lines 40-41) only asserts the README
names the two prompt file paths, not their content.
No other file in the grep hit (`execution_policy_test.exs`,
`review_packet_test.exs`, `reviewer_mutation_test.exs`, etc.) asserts
literal prompt prose for developer.md/reviewer.md beyond
`harness_contract_test.exs`; they mostly test controller behavior around
verification ownership. Any new prompt wording should get an assertion in
(or beside) `harness_contract_test.exs`'s placeholder test, and ideally a
new prompt-content test for the "done when" / self-review / checked-text
phrases, run once and shared by both harness fixtures — keeping the
harness-neutral guarantee.

## 3. Verdict schema and self-hosting risk

`lib/kogen/harness/verdict.ex`: `schema/0` is the fixed
`additionalProperties: false` schema with exact required keys `["scenarios",
"dispositions", "findings", "candidate_id", "attempt_token", "verdict"]`
(77-86, 234-236). Critically, `schema/1` (91-125) already builds a
**per-launch variant**: when the controller has ledger paths for this
attempt it adds a required `ledger` array to a *copy* of the base schema
(98-125), and `parse/validate` take a `ledger?` flag to select which key-set
is expected (128-160, 234-238). This is the exact precedent needed: the
verdict schema is not compiled once — it's already built fresh per Review
launch from Candidate-specific data.

Recommendation: add "what was/wasn't checked" the same way — as an
**optional, launch-conditional field** built by the *new* controller (the
Candidate under Shaping, once implemented), not by adding an unconditional
required key to `@verdict_schema`/`schema/0`. Two safe shapes:
(a) reuse existing free-text `reason` fields in `scenarios`/`dispositions`/
`findings` and just add prompt wording asking the Reviewer to mention what
it inspected and what it didn't reach — no schema change at all, so this
Build's own Review (validated by **main's** compiled `Verdict` module) stays
valid regardless of what the new reviewer.md says, since prose in `reason`
is unconstrained text; or
(b) add a new optional array-valued key (e.g. `checked`) only inside
`schema/1`-style per-launch construction, gated the same way `ledger` is
gated, with reviewer.md phrased conditionally ("when your schema includes a
`checked` field, ..."). Because self-hosting means *this* Build's Review is
validated by main's already-compiled `Kogen.Harness.Verdict.schema/0` (no
`checked` key, `additionalProperties: false`), any unconditional new
required field would make the Candidate's own Reviewer verdict invalid
against main's validator and fail this Build. Option (a) is safest and
needs no schema change; option (b) mirrors the Draft's own planned
`per-launch-verdict-schema` scenario (scenarios.yaml:649-669, in
`.kogen/intents/drafts/build-reliability/`), which already adds
launch-specific required fields (`receipt`, evidence path pattern) beyond
what main's current schema has — confirming this general approach is
already the accepted pattern for this codebase, but only when the *new*
controller code (not main's) builds and validates against the new schema
for that launch.

## 4. Research file (`plan/research/prompt-practices.md`)

- "Review the diff against main with specific criteria before a human sees
  it ... **Developer:** before ending each turn, review `git diff` against
  every scenario's `then` and `wrong_result`, and fix gaps. That's cheaper
  than a Review rework cycle."
- "Whole task in one message, **named finish line** ... **Developer:** add
  an explicit 'Done when' list: every scenario true (not just plausible),
  every declared proof selector present and passing focused, no path
  outside guards, notes written."
- "Mark anything unconfirmed and say where you looked ... **Reviewer:** each
  finding says what was checked and what wasn't (fits the evidence
  locators)."
- Constraint: "Keep prompts harness-neutral... Prompt wording is proved
  offline by prompt-contract tests... We don't claim improvements without
  numbers."
- Placement: "Roadmap Intent 36, role prompt tune-up: a small, offline
  Intent... The Developer scratch checklist goes with CTX-05" (i.e. the
  Draft-progress-checklist item is explicitly deferred, matching the
  Shaper's note that it's out of scope here).

## 5. Offline proof of "Developer actually self-reviews"

Given the Developer's final output is free prose consumed only by the
Reviewer/Jev and never parsed by Kogen code (developer.md:161-163, "no Kogen
code parses your final message"), there is no existing structured hook to
attach a checkable signal to without inventing new plumbing. Realistic
offline proof is necessarily prompt-content assertions (the phrase/step
exists, in the harness-neutral file, exercised by both fixture harnesses)
plus fake-harness scenario tests already used elsewhere
(`test/support/scripted_build_fixture.ex`,
`test/kogen/live_shape_to_build_test.exs`) that script a fake Developer
turn and assert the controller-visible behavior around it (e.g. that a
Developer note format is accepted/handled). One option that stays
proof-without-plumbing: extend the existing "For each scenario, say plainly
whether your own work on it is done" instruction (169-171) to require
naming, per scenario, one concrete self-check performed against `then`/
`wrong_result` — this reuses the *already-consumed* channel (Jev reads
Developer notes per scenario, per reviewer.md:90-96) rather than adding an
unread field. That keeps it a text-content test (assert the prompt asks for
it) rather than a build-behavior test, since nothing downstream currently
parses Developer notes structurally — matching the constraint that adding a
"required section the controller reads" would be new plumbing without an
existing caller.
