> **Historical.** This batch approval was given in the driver session, outside Kogen Shaping,
> and covered the revision before the 2026-09-25 Claude Shaping continuation, which still had
> the auditor. It does not cover the current revision; see `approval.md`.

# Approval

Current state: **approved by the human Shaper as a roadmap outcome in the 2026-09-25
batch.** The package stays `status: draft` in `drafts/` until the driver finishes the
audit and moves it to `approved/`. The driver does not start the Build before Intent #1,
`bounded-reviewer-evidence`, has landed on `main`.

The Shaper's words, in the driver session on 2026-09-25:

> "so yeah, I approve: 1. bounded-reviewer-evidence 2. cross-harness-adversarial-roles
> 3. shaping-preflight-audit 4. verification-fortification 5. isolated-candidate-workspace"

confirmed with:

> "that should count as my explicit approval"

and later:

> "you gotta make sure all the intents are ready to build tho … utilize jev, Astra
> medium, Sol high … I approve whatever you guys decide! so you can build, drive this
> without me … make sure you don't stop for any bullshit"

**Scope of this approval:** the outcome of ROADMAP row 2 (ID 1, features HAR-02 and
HAR-03). That covers:

- four routes;
- Reviewer, Expert and an auditor role on the adversarial harness;
- the Codex compatibility fix;
- live checks `live-native` and `live-reviewer-rework`.

Technical decisions inside that outcome were delegated to the driver and its shaping
agents (see `questions.md`). Work beyond the row is not covered. Two decisions are reported to the driver rather than widened silently: the default-route
flip moves to a follow-up (risk `default-route-flip-deferred`), and the 240 s turn limit
replaces the historical 300 s (risk `compatibility-live-variance`).

Shaped against `main` at `2909f557c57f49b32e4453a0264e9e48c6fc1676`. The package depends on
Intent #1. Risk `baseline-moves-before-build` requires re-validation on the `main` that
contains #1 before this Build.

Approval grants no source, test or configuration write beyond what a Build of this Intent
performs within `may_change_guarded_paths`.

## Historical approvals (do not cover this revision)

- 2026-09-25T06:23:24Z, "bro let's build I don't fucking care": the revision that Build
  `kdUszVF4Gw71QsxsppvSKc2b` failed (`historical-approval-2026-09-25.md`).
- 2026-09-24T13:51:25Z, "ok, I approve that original intent": the ledger revision
  (`historical-approval-2026-09-24-ledger.md`).
- 2026-09-24T12:18:57Z, "Approved.", plus the default route
  (`historical-approval-2026-09-24-default-route.md`).
- 2026-09-24T12:17:01Z, "Approved." (`historical-approval-2026-09-24.md`).

## Re-approval after Build o-DlRi (2026-09-25)

The driver added scenario `retained-evidence-with-record-sidecars` (a latent #1 defect that blocked the retained-evidence audit) and the stash reference. This is within the ROADMAP outcome and covered by the Shaper's batch approval ("I approve whatever you guys decide!", "NO STOPPING THE BATCH … FIX AND RESHAPE").
