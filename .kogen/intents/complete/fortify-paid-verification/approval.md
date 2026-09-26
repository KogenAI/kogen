# Approval

Current state: **Approved.** The Shaper gave explicit approval in the
Shaping conversation that began 2026-09-25T04:28:26.887967Z (route `claude`,
model `claude-opus-5-5`, effort `medium`), against `main` at
`2909f557c57f49b32e4453a0264e9e48c6fc1676`. The Shaper's words: "so yeah, I
approve: … 4. verification-fortification", confirmed with "if I … said I
approve already, that means I approved those … intents, so that should count
as my explicit approval". The approved contract is this reconciled revision:
12 scenarios, verification `check` + `live-shape-to-build` + `live-native`,
with the Codex retry and turn budget handed to
`cross-harness-adversarial-roles`.

Build order: fourth, after `bounded-reviewer-evidence`,
`cross-harness-adversarial-roles` and `shaping-preflight-audit`. Before this
Build starts, re-run the Build preflight on the then-current `main`
(risk `baseline-moves-before-build`). A contradiction needs a Shaping
continuation and fresh approval. The package passed contract load, the
verification plan and the policy preflight immediately before this approval.
Approval grants no source, test or configuration write beyond what a Build of
this Intent performs within `may_change_guarded_paths`.

## Revision by the driver after preflight (2026-09-25)

Re-approved under the Shaper's delegated approval. The Shaper's words
(2026-09-25, driver session): "so yeah, I approve: 1. bounded-reviewer-evidence
2. cross-harness-adversarial-roles 3. shaping-preflight-audit
4. verification-fortification 5. isolated-candidate-workspace", "that should
count as my explicit approval", and "you gotta make sure all the intents are
ready to build tho … utilize jev, Astra medium, Sol high … I approve whatever
you guys decide! so you can build, drive this without me … make sure you don't
stop for any bullshit". The scope is still ROADMAP order 4 (IDs 2+3), and the
live checks are still `live-shape-to-build` and `live-native`.

The driver re-ran the Build preflight (risk `baseline-moves-before-build`) on
2026-09-25. It checked main `2909f557c57f49b32e4453a0264e9e48c6fc1676` and the
designs of `bounded-reviewer-evidence` (Draft), `cross-harness-adversarial-roles`
(Draft, with reference stash `cross-harness-candidate-2026-09-25`) and
`shaping-preflight-audit` (not yet shaped). Id, slug, title, the 12 scenario ids,
`verified_by` and paid targets are unchanged. Changes:

1. `intent.yaml`: `priv/kogen/test-reliability.yaml` was added to
   `may_change_guarded_paths`. This Intent edits about 15 cataloged tests, and
   `check` fails on stale `source_sha256` bindings. Without the guard, the
   refresh would be a guarded-path violation. Also added: a `reapproval`
   block, a `scope` field, and a `shaping_continuations` entry for this driver
   session.
2. `controller-owns-verification`: the route wording now covers the hybrid
   routes. The new controller is the only writer of the local Verification
   Record and history (`Kogen.Check`) in today's format, archived only per
   outer attempt, so the unedited `live-reviewer-rework` audit keeps working.
   The live-reviewer-rework owner and support files stay byte-identical. The
   `paid_reason` names the post-cross-harness default route. `lib/kogen/check.ex`
   was added to `affected_paths`.
3. `failed-verification-resumes-same-developer`: `bounded-reviewer-evidence`'s
   superseded-objection rule now works on controller cycles. Added
   `test/kogen/superseded_objection_test.exs` (created by that Intent) as a
   selector and `lib/kogen/build/review_packet.ex` to `affected_paths`.
4. `same-candidate-failed-only-retry`: the reuse mark also appears in the
   review packet. `review_packet.ex` was added to `affected_paths`.
5. `stop-route-bootstrap-only`: now states the other inputs main's controller
   reads from the Candidate. These are the rehearsal trace identities (via
   `scripts/check/rehearsals.exs`), the role prompts (via
   `render_reviewer_prompt/3` and `developer_prompt/2`, with main's
   exact-key verdict parser) and the test-reliability ledger (hash-only
   refresh, witnesses intact). The Candidate's preflight no longer requires
   the Stop script, which is the expand step for the follow-up. Added the
   selector `test/kogen/test_reliability_catalog_test.exs` and the affected
   path `priv/kogen/test-reliability.yaml`.
6. `stop-free-compatibility-fixture`: the "fresh Reviewer requirements
   remain" wording contradicted `cross-harness-adversarial-roles`, which removes
   the scripted stand-in Reviewer. The retained requirements now match that
   Intent: PreToolUse block, hostile discovery, interactive Shaping, Developer,
   exact-session resume and scout helper. Its two-attempt manifest also stays
   unchanged.
7. `no-special-gate-target`: "Review input" now reads "review packet", and
   `review_packet.ex` was added to `affected_paths`.
8. `verification-surface-ledger`: the ledger now reaches Review through
   `bounded-reviewer-evidence`'s 65,536-byte review packet. That means one
   index entry per item, with full diffs retained and cited by locator and
   digest, never inlined. Dispositions go in a new `ledger` verdict field,
   required only when a ledger is supplied, so main's controller still accepts
   this Build's own verdicts. Added `test/kogen/review_packet_test.exs` (created
   by that Intent) as a selector, and `review_packet.ex`, `contract.ex` and
   that test to `affected_paths`.
9. `risks.yaml`: `self-hosting-settlement` gained a corrected anchor
   (`build.ex:610-619`) and the three extra Candidate inputs.
   `overlapping-intents` was rewritten for the current order. `appetite`
   dropped the moved Codex retry. `baseline-moves-before-build` records this
   preflight. New risks: `live-targets-on-hybrid-default-route` and
   `shaping-audit-rule-drift`.
10. `INTENT.md`, `questions.md`, `references.yaml`: the same changes in
    prose; the non-goal now allows the hash-only ledger refresh and excludes
    editing the live-reviewer-rework owner; stale `approved/` paths of other
    Intents now point to their Draft locations.

11. After the adversarial audit: the `given`s of `no-special-gate-target` and
    `same-intent-catalog-change` now say they describe fixture Intents and
    later Intents, not this Build, and this Build keeps `check`, the Makefile
    and the catalog unchanged. The live-test evidence of
    `controller-owns-verification` explains why the nested fixture Build runs
    the Candidate's controller. `INTENT.md` gained a short "How to read the
    scenarios" note. `stop-route-bootstrap-only` gained the selector
    `scripts/check/rehearsals.exs`. Both auditors had read these scenarios as
    claims about main's controller.

The audit record (deterministic validators, GPT-6 Sol high, GPT-6 Astra medium,
Jev) is in `evidence/preflight-2026-09-25/`. What still has to be re-checked on
the landed main is in the driver's READINESS note
(`plan/staging/fortify-paid-verification-READINESS.md`).

## Driver re-preflight at 363c20af (2026-09-25/26)

Recorded by the driver session under the Shaper's delegation. The Shaper's
words (2026-09-25, driver session): "you don't need me for anything, you can
do everything yourself … I approve everything", and "NO STOPPING THE BATCH …
YOU FIX AND RESHAPE AND SHIT UNTIL ALL GOES WELL". Scope is unchanged: ROADMAP
order 4, live checks `live-shape-to-build` and `live-native`.

Baseline: main `363c20af202c8702d76ddcb1dadcf6a21996779c`
(`bounded-reviewer-evidence` 22a2db95 and `cross-harness-adversarial-roles`
363c20af landed; #2 has no auditor role and keeps `default_route: claude`).
`shaping-preflight-audit` is parked for the Shaper, so this Intent builds
third, on 363c20af, and uses none of its code (a reordering, not a scope
change; the alignment of that Intent's rule checks with this controller is
recorded in its PARKED note). The Build runs with
`--route claude-dominant-adversarial-codex`. Id, slug, title and paid targets
are unchanged. The scenario count is 13. Changes:

1. `shape-to-build-retains-record-sidecars` now matches #2's landed fix:
   `Evidence.resolve/2` verifies sidecars beside the retained record, and only
   the Reviewer-rework fixture copies them. A new support module
   `test/support/live_tracking_retention.ex` retains each nested Build's whole
   tracking directory for the Shape fixture, with an offline proof in
   `build_evidence_test.exs` (build-failure lesson 1).
2. `verification-surface-ledger`: both Reviewer harnesses are constrained by
   `Kogen.Harness.Verdict.schema/0` (`additionalProperties: false`), so the
   schema is chosen per launch and gains a required `ledger` only when a
   ledger is supplied; without one it is byte-identical to today's.
   `verdict.ex`, both harness adapters and the fake Reviewers are affected
   paths. This Build's own Reviewer is Codex, bound by main's schema.
3. `controller-runs-proof-selectors`: `base_cache` can't copy controller
   volatile state such as `.kogen/build.lock` (lesson 13).
4. `controller-owns-verification`: the paid reason names the nested fixture's
   actual route (`claude`). Evidence texts of several scenarios now name the
   control that catches each `wrong_result` (Jev audit).
5. Risks: anchors re-read at 363c20af (`build.ex:664-673`), the auditor-role
   assumption removed, `overlapping-intents`, `baseline-moves-before-build`,
   `live-targets-on-hybrid-default-route` and `shaping-audit-rule-drift`
   rewritten. `references.yaml` points at `complete/` for #1 and #2 and names
   the 240 s compatibility turn limit. `questions.md` uses the Shaping-audit
   section grammar.

Validators and audits for this revision are in
`evidence/repreflight-2026-09-25-363c20af/`.

## Historical approval (superseded)

The Shaper approved an earlier contract ("I approve") in the shaping
conversation that began 2026-09-24T15:09:41.881577Z (route `claude`, model
`claude-opus-5-5`, effort `medium`), against `main` at
`2909f557c57f49b32e4453a0264e9e48c6fc1676`. That contract included the native
target split. Build `G8XQmw8OuNa-fPqe0TlQ0p35` stopped with `cannot_comply`,
because Jev read the Developer's contract objection at confidence 1.00 before
Review. The record is at
`.kogen/runtime/scenario-tracking/G8XQmw8OuNa-fPqe0TlQ0p35/record.json`. The
approval does not cover this revision.

## Driver note after Build uaYa_xCH (2026-09-26)

Retry reuses the proven branch; no contract change beyond the root-cause evidence. Covered by the Shaper's "I approve everything".
