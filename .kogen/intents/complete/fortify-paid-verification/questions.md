# Questions

## Ask the Shaper

None. Both earlier questions were settled on 2026-09-25: the Codex turn budget
and the fresh-fixture retry belong to `cross-harness-adversarial-roles`, which
is built before this Intent. This Intent keeps only the fixture's Stop removal
(scenario `stop-free-compatibility-fixture`).

## Shaper answers

1. Approval of the batch (2026-09-25, driver session): "so yeah, I approve:
   1. bounded-reviewer-evidence 2. cross-harness-adversarial-roles
   3. shaping-preflight-audit 4. verification-fortification
   5. isolated-candidate-workspace" and "that should count as my explicit
   approval".
2. Delegation (2026-09-25, driver session; plan/SUBAGENT-SHAPING-BRIEF.md and
   plan/BATCH-REPORT-2026-09-25.md): "you gotta make sure all the intents are ready to
   build tho … I approve whatever you guys decide! so you can build, drive
   this without me … make sure you don't stop for any bullshit", and later
   "I approve everything".
3. The Shaping-conversation answers are quoted under `## Settled` below
   (fifth and sixth turns).

## Left undecided

None.

## Assumed

1. **Build before the parked `shaping-preflight-audit`, without its code.**
   Reason: that Intent is parked for the Shaper (plan/staging/
   shaping-preflight-audit-PARKED.md), and nothing in this ROADMAP row needs
   it. Its planned rule checks (`proof_errors/4`, `frozen_paths/0`,
   `controller_paths/0`) are aligned with this controller when it builds, as
   its PARKED note records. Undo: none needed.
2. **One retention module for the Shape fixture** (scenario
   `shape-to-build-retains-record-sidecars`). Reason: a private `defp` in a
   live test cannot be proved offline, and copying the whole tracking
   directory covers #2's sidecars and this Intent's new verification files
   (build-failure lesson 1). Undo: call
   `Kogen.ReviewPacketAudit.preserve_record_versions!/2` inside the test's own
   `preserve_tracking/3` instead; the offline proof is then only #2's
   relocation test.
3. **The nested `live-shape-to-build` Build runs on `default_route: claude`.**
   Reason: #2 landed without the flip (ROADMAP 10a). Undo: none needed; if 10a
   lands first, the fixture follows the new default.

## Settled

- **Driver preflight revision (2026-09-25, under the Shaper's delegated
  approval: "I approve whatever you guys decide!").** These technical
  decisions were taken so the package builds right after the three earlier
  Intents:
  - The ledger reaches the Reviewer through the bounded review packet of
    `bounded-reviewer-evidence`. Each item's full diff is a retained file cited
    by locator and digest. It is not inlined in the packet.
  - Ledger dispositions use a new `ledger` verdict field, required only when a
    ledger is supplied. That keeps this Build's own Reviews (run by main's
    controller with the Candidate's `reviewer.md`) valid under main's
    exact-key verdict parser.
  - The new controller writes the local Verification Record and history in
    today's format. This keeps `live-reviewer-rework` working without editing
    its owner. Editing it would add a third paid target (DIRECTION D8), beyond
    ROADMAP row 4's two.
  - The Candidate's preflight drops the Stop-script requirement. This is the
    expand step (DIRECTION D9) that lets the follow-up delete the scripts.
  - Only hash refreshes are allowed in `priv/kogen/test-reliability.yaml`, so
    the file is guarded.
  - `live-shape-to-build` runs on whatever default route main has (`claude` at
    363c20af). It is not pinned. See risk `live-targets-on-hybrid-default-route`.

- **All verification-integrity work in this Intent (Shaper, 2026-09-25,
  sixth turn):** "everything and anything about that goes in". The expert
  design was adopted, with its open points settled by the Shaping Controller:
  `proof.base` is required for new contracts and legacy contracts are
  labelled; preservation selectors get the base-bytes code check; the base
  suite runs on the Candidate as a Review report; `weakening` goes to Review
  rework; base-fingerprinting tests are left to Review.
- **Run edited live tests here (Shaper, 2026-09-25, fifth turn):** scenario
  `controller-owns-verification` selects `live-shape-to-build` ("a. yes, we
  should edit and run it here"). Scenario `stop-free-compatibility-fixture`
  selects the unsplit `live-native`, because this Intent edits the Codex
  compatibility owner. The Shaper accepts two paid targets. This supersedes the
  third-turn "no paid target" decision.
- **Make stays the only runner (Shaper, 2026-09-25, fifth turn):** "we can
  keep the make hardcoded". The expert confirmed that `command` entries add no
  safety. They were removed from `no-special-gate-target`.
- **Separate follow-up verification Intent (Shaper, 2026-09-25, fifth turn):**
  the roadmap-size constraint is lifted ("everything is open for debate and
  change"). Stop script removal and the `live-native` split go to a small
  follow-up Intent, not to `cross-harness-adversarial-roles`.
- **No hardcoded gate name (Shaper, 2026-09-25):** `check` is no longer
  special. `verified_by` is the complete list.
- **Same-Intent target introduction (Shaper, 2026-09-25):** allowed, through
  declared `catalog_changes.add` with the integrity guardrails.
- **Kogen-only two-step guidance (Shaper, 2026-09-25, fourth turn):** it goes in
  `README.md`, not the shared Shaping prompt.
- **Fewer live targets in Shaping (Shaper, 2026-09-25, third turn):** covered by
  the shared prompt and a Kogen README policy. An edited live test's target is
  selected in the same Intent.
- **Compatibility owner retry (moved):** now owned by
  `cross-harness-adversarial-roles`. Historically on `timed_out` only, one rerun in a fresh
  fixture. Both attempts' evidence is kept, and it passes only if the second
  attempt fully passes. Kogen core never retries by provider class.
- **Bootstrap:** two-step Stop removal. The Stop scripts stay as a
  v1-context-only path, so this Build finishes automatically under main's
  controller. Verification never runs Candidate-authored controller code.

## Dispositions

The 2026-09-25 audit findings and their dispositions are in the driver's
READINESS note and in `evidence/preflight-2026-09-25/` and
`evidence/repreflight-2026-09-25-363c20af/`.

- Editing `.codex/hooks/check.sh`, `stop_runner.py` and `verification_policy.py`
  is this Intent's DIRECTION D9 expand step: the v1 Stop path main's
  controller settles through stays intact, and main's preflight still finds
  every file it requires.

## Follow-up verification Intent (to be shaped; not approved backlog here)

- Delete `.codex/hooks/check.sh`, `.codex/hooks/stop_runner.py` (and
  `.codex/hooks/environment.py` if unused) and both Stop registrations.
- Split `live-native` into narrow targets through `catalog_changes.add`, under
  this Intent's controller.
- Add the integrity fields (`verification_surface`, `focused_runner`,
  `base_cache`) to Kogen's catalog, which switches integrity on for later
  Builds.
- Select the narrow compatibility target and `live-shape-to-build`.
- Afterwards, re-shape `cross-harness-adversarial-roles` to select a narrow
  native target.

## Historical Draft notes (superseded)

- Earlier revisions required deleting Stop in this Build with a manual finish,
  or a Candidate-loaded verifier. The Shaper chose the two-step removal.
- The approved 2026-09-24 contract kept the native target split in this Build.
  Build G8XQmw8OuNa-fPqe0TlQ0p35 stopped with `cannot_comply`, because main's
  controller rejects catalog changes after admission.
- Third turn, 2026-09-25: every scenario was `[check]` only. The fifth turn
  superseded this.
- Target-level red-on-base, recipe freezing, replacement owner partition and
  `command` entries were proposed in the second through fourth turns. The
  integrity design replaced them in the sixth turn.

## Later, not blocking

- Re-check `bind-controller-generation` and `isolated-candidate-workspace`
  against the new verification route.
- A controller-level target timeout and cancellation policy, if needed.
