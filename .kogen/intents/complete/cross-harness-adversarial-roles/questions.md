# Questions

## Open

None. On 2026-09-25 the Shaper delegated every technical decision in this batch to the
driver ("I approve whatever you guys decide! so you can build, drive this without me").
Decisions that need the driver's attention before the Build are listed in risks
`default-route-flip-deferred`, `depends-on-bounded-reviewer-evidence` (the pre-Build probe gate)
and `baseline-moves-before-build`.

**Approval state.** The Shaper approved this revision ("approved") in the Kogen Shaping
continuation at 2026-09-25T12:22:41Z. The driver-session batch approval is now historical
(`historical-approval-2026-09-25-batch.md`).

## Decided by the Shaper in the Claude Shaping continuation (2026-09-25T12:16Z)

- **No auditor in this Intent.** Shaper: "we don't want auditor now / Remvoe that
  bplumbing / auditor comes in the shaping quality/audit intent / so it's stupid to have the
  plumbing now for things taht aren't wired in". The auditor role slot, route keys,
  readiness entry, `role_context(:auditor)`, `launch_auditor/4`, `KOGEN_ROLE=auditor`, and
  the auditor setup guards all move to `shaping-preflight-audit` (#3). This narrows ROADMAP
  row 2's "Reviewer, Expert and auditor on the adversarial harness" to Reviewer and Expert.
  The title changes to match. The Expert's setup-guard fix stays.
- **Reuse the accepted Build `30b96fa0` from the reflog, minus the auditor.** Shaper: "we
  already had a build completely done / check reflog … that stuff should mostly be reused
  except the auditor plumbing parts" and "during the build, developer should probably take
  all that stuff from reflog and just remove that shaping auditor plumbing". Build
  `sjqVuqHRgv3YXUVdET-YlksA` ended `accepted`, was committed as `30b96fa0` (parent
  `22a2db95`) and was then reset away. It supersedes stash `2294e64a` as the reuse base.
- **Engineering choice (Shaping controller):** the contract requires the auditor to be
  absent. It does not add a refusal for an `auditor` key, because main has no general
  unknown-route-key refusal and a dedicated one would itself be auditor plumbing.

## Open items for the Shaper or driver (not product questions)

- **Give `30b96fa0` a durable ref before the Build.** Right now only the reflog reaches it,
  and unreachable reflog entries expire and can be garbage-collected. Suggested:
  `git tag cross-harness-candidate-2026-09-25c 30b96fa0` or a stash-style ref. Shaping does
  not write refs.
- **#3 `shaping-preflight-audit` needs a Shaping continuation.** Its staged package
  assumes this Intent provides the auditor slot and `launch_auditor`.
- **This draft's staging copy** in `plan/staging/cross-harness-adversarial-roles/` is now
  behind this package.

## Reconciled in the Claude Shaping continuation (2026-09-25T12:16Z)

- #1 has landed (`22a2db95`), and the admission validation passed on it
  (`evidence/admission-validation-2026-09-25-22a2db95.md`). The statements that said the
  Build must wait for #1 are now past tense.
- The contradiction between "Reference Candidate: never apply" and "Reuse: restore the
  stash" is resolved: `2294e64a` (post-#1) is the reuse base, restored with `git show`.
  `6905e9a4` (pre-#1) is superseded. Neither stash is applied, popped or dropped.
- `retained-evidence-with-record-sidecars` is an explicit exception to the non-goal "anything
  #1 owns". The fix is limited to sidecar lookup and the fixture's preserve step. It is also
  linked to risk `stale-test-reliability-bindings`, because it edits a cataloged test.

## Settled in this revision (driver session, 2026-09-25, under the Shaper's delegation)

- **Depend on Intent #1 `bounded-reviewer-evidence`, don't absorb it.** The Sol and Astra
  analyses both recommend a separate evidence Intent before cross-harness. The Shaper's
  batch order puts it first. This Intent consumes #1's review packet, metadata-only
  citations, Codex output limit, external fixture root and stale-objection fix. It must
  keep them on every new launch path. The old risk `codex-reviewer-rework-duration` is
  replaced by `depends-on-bounded-reviewer-evidence`. Raising a timeout stays forbidden
  (Shaper, 2026-09-25: never raise timeouts to make tests pass; fix the cause).
- ~~**The auditor role is a slot plus launch plumbing.**~~ **Superseded 2026-09-25 by the
  Shaper: no auditor in this Intent (see above).** Historical text: ROADMAP row 2 lists "Reviewer,
  Expert and auditor on the adversarial harness". Intent #3 runs the auditor. This Intent
  adds:
  - the `auditor` role in the route model: required in hybrid routes, and resolved to
    the Reviewer profile in clean routes, so clean-route bytes and the many offline
    fixture configs stay unchanged;
  - the Shape readiness entry;
  - `role_context(runtime, :auditor)` and `Kogen.Harness.launch_auditor/4`;
  - the `KOGEN_ROLE=auditor` identity with editing tools denied on Claude Code;
  - the setup guards.
  It adds no prompt, no findings schema and no invocation.
- ~~**Auditor profiles.**~~ (superseded, historical) The auditor mirrors the Reviewer of the same harness: `gpt-6-sol`
  at `high` on Codex, and `claude-opus-5-5` at `medium` on Claude Code. Its job, an
  adversarial read of someone else's work, is the Reviewer's job. #3 may retune it with
  evidence.
- ~~**Why clean routes resolve the auditor instead of declaring it.**~~ (superseded, historical) More than 15 offline
  test files build their own route configs (see `default_route` in `test/`). Requiring a
  new key would churn most of them and their ledger hashes for no behavioural gain. The
  Expert already resolves the same way (`helpers.expert`).
- **`mix kogen.expert` stays the Expert channel from another harness**, as in the
  reference Candidate. The live case runs it as a subprocess with the frozen
  `KOGEN_EXPERT` assignment, because that is how a Claude Developer really uses it. The
  in-process call in the reference Candidate left the task's stdin and argument handling
  unproved.
- **Codex setup guard.** `lib/kogen/codex.ex` `management_allowed!` must also refuse the
  `expert` role (the `auditor` part is superseded). The reference Candidate changed only the Claude Code guard.
  `lib/kogen/codex.ex` is added to the guarded paths.
- **Keep `default_route: claude` here; flip it in a follow-up** (expand then contract,
  DIRECTION D9). Flipping it here would require editing `live_test.exs` and
  `live_shape_to_build_test.exs`, and D8 would then require running `live-general` and
  `live-shape-to-build`, which this row does not allow. The Sol and Astra audits both
  rated editing without running as blocking. The hybrid route is proved by explicitly
  routed live cases instead. This defers a detail of the 2026-09-24 historical approval
  ("default route as part of this Intent") and is flagged to the driver (risk
  `default-route-flip-deferred`).
- **The role matrix is an additive `role_assignment` key.** The existing `route` map in
  the record and the summary keeps its exact shape, so `live_shape_to_build_test.exs`,
  `evidence.ex` and other exact-shape consumers need no change. The reference Candidate
  put the matrix inside `route`, which forced live-owner edits.
- **Keep the 240 s compatibility turn limit.** The Shaper's 2026-09-25 rule is never to
  raise timeouts to make tests pass and to fix the cause. Removing the stand-in Reviewers
  fixes the cause, and the measured remaining turns (at most 135 s) fit 240 s. This
  supersedes the historical revision's 300 s.
- **Live checks are `live-native` and `live-reviewer-rework` only** (ROADMAP row 2 and the
  driver's instruction). `live-native` proves the compatibility fix and the real Codex
  Expert and auditor launches. `live-reviewer-rework` proves the real cross-harness Build
  boundary.

## Settled earlier (historical, still binding)

- **The compatibility test gets no stand-in Reviewer** (Shaper, 2026-09-25: "you gotta
  use proper reviewer otherwise it doesn't make sense"). Tailored Reviewer prompts
  (probe v1) were rejected. The real Codex Reviewer is proved by `live-reviewer-rework`.
  The historical revision set the per-turn limit to 300 s. **This revision keeps main's
  240 s** (see below), and a rerun happens only if it fits the 15-minute ceiling.
- **Keep the compatibility work in this Intent** (Shaper, 2026-09-25: "it's required for
  cross-harness so I'd keep it here").
- **This Intent takes the Codex compatibility reliability work from
  `fortify-paid-verification`.** That work is the root-cause fixes, a per-turn budget
  measured on GPT-6 Sol, and one whole rerun in a fresh fixture only on `timed_out`, with
  both attempts' evidence kept. The policy stays inside the compatibility owner.
  `fortify-paid-verification` keeps only the removal of the Stop hook from the fixture.
  That package is not edited from here.
- **Main's verification machinery is unchanged** (Shaper, 2026-09-25): no change to the
  Stop hook, `Makefile` or `priv/kogen/verification_targets.yaml`. `live-native` stays one
  unsplit target, because main's controller stops a Build whose catalog changes.
- **The whole compatibility test must not run much longer than about 15 minutes**
  (Shaper, 2026-09-25: "it would be crazy going about 15 minutes").
- **Earlier accepted scope:**
  - The two single-harness routes remain.
  - ~~The default route is `claude-dominant-adversarial-codex` (Shaper, 2026-09-24).~~
    **Superseded in this revision:** the default stays `claude`, and the flip is ROADMAP row 10a
    (see "Keep `default_route: claude` here" above and risk `default-route-flip-deferred`).
  - The Claude-dominant route runs Shaping and Developer on Claude Code and the adversarial
    roles on Codex. The Codex-dominant route is the mirror image.
  - Helpers stay native to their root role's harness.
  - The role-level routing contract is reusable by a Shaping auditor. (#3 now delivers
    the `auditor` slot itself.)
- **Superseded:** the note that "the Shaper restores the earlier Candidate into the
  worktree after the Build starts" no longer holds. The stash is reference material only
  (driver, 2026-09-25). Paid probe caps and the 3-in-a-row target were waived by the
  Shaper on 2026-09-25.

## Resolved by inspection

- The `cannot_comply` objections of Build K9Fu72yG came from the reliability ledger path
  missing from the allowed paths. It has been in the guarded paths since the 2026-09-24
  revision.
- The credential-store and Codex Shaping-turn failure classes of the compatibility test
  were fixed on main by the GPT-6 upgrade (`evidence/compatibility-diagnosis-2026-09-25.md`).
- Build kdUszVF4's cycle 3 passed every target. Its `cannot_comply` came from a stale
  objection, which #1 fixes (`evidence/build-failure-2026-09-25.md`, correction).
- The `live-shaping-quality` driver resolves its Codex profiles by top-level
  `harness: codex`, never `default_route`. The hybrid routes have no top-level harness, so
  it is unaffected, as long as exactly one clean Codex route remains.
