# Admission validation on post-#1 main (2026-09-25, Shaping continuation, Claude)

Checkout: `main` at `22a2db955e8941941a80e44c5ce3649cfb449945` ("Give the Reviewer bounded,
Candidate-bound evidence"), which contains Intent #1 (`bounded-reviewer-evidence`, now in
`.kogen/intents/complete/`).

## Package validator (risk `baseline-moves-before-build`)

Read-only probe script, run from the repository root against the draft path:

```
MIX_ENV=test mix run --no-start <scratch>/validate.exs
```

It calls, in the Build's order, `Kogen.Intent.read/2` (base `.kogen/intents/drafts`),
`Kogen.Build.Contract.load/1`, `Kogen.Build.VerificationPlan.load/0`,
`VerificationPlan.build/3` with the package's `may_change_guarded_paths`, and
`Kogen.VerificationPolicy.preflight/1`.

Observed:

```
intent.read: {:ok, %{id: "01a0d2c5-e2aa-7138-9548-975e49df3ea2", ...}}
contract.load: :ok
targets: ["check", "live-native", "live-reviewer-rework"]
plan.build: :ok
policy.preflight: :ok
```

Limitation: run against `drafts/`, not `approved/`; the Build reads `approved/`. The package
bytes are the same after the move.

## Offline selectors

Every `proof.offline` test file named in `scenarios.yaml` exists at this HEAD (checked with
`test -f` for all 27 files).

## #1 controls present at this HEAD

- `tool_output_token_limit` in `lib/kogen/codex/environment.ex`.
- `write_review_packet/3` in the Reviewer path of `lib/kogen/build.ex` (~718).
- `ReviewPacket.superseded_objection` in `lib/kogen/build.ex` (~415-427).
- `snapshot_references` (metadata-only citations) in `lib/kogen/build.ex` (~556, ~797).
- `assert_outside_checkout!/2` and `assert_logged_in!/1` in `test/support/review_packet_audit.ex`.

## Sidecar defect (scenario `retained-evidence-with-record-sidecars`) confirmed in source

- `lib/kogen/build/evidence.ex` `record_version/2` resolves each sidecar only via
  `resolve_path(sidecar, checkout_root)`, i.e. the checkout-relative path stored by
  `Tracking` (`record-versions/<sha256>.json` next to the original record).
- `test/support/live_reviewer_rework_fixture.ex` `preserve/3` copies only
  `scenario-tracking/*/record.json` into the log directory, never `record-versions/`.
- So retained evidence of a record that cites itself cannot resolve after the fixture is
  deleted, matching Build `o-DlRi_iHnqIwmxfcCz-obe0`'s failure.

## Reference Candidate

`stash@{0}` `cross-harness-candidate-2026-09-25b` is commit `2294e64a1a2461dbc163c2f1bffead5f56192cfa`,
whose first parent is `22a2db95…` (this HEAD). It does not predate #1. The older
`cross-harness-candidate-2026-09-25` (`6905e9a4…`) has parent `2909f557…` and does.

## Later in this visit: reuse base changed to 30b96fa0

The Shaper pointed to the reflog. `30b96fa0e2c954e4804733df805a36823262e875` (parent `22a2db95`)
is the commit of accepted Build `sjqVuqHRgv3YXUVdET-YlksA`
(`.kogen/runtime/scenario-tracking/sjqVuqHRgv3YXUVdET-YlksA/record.json`, `status: accepted`),
reset away at 15:15. It already contains the sidecar fix: `record_versions/3` looks for
`record-versions/<sha256>.json` next to the resolved record. `git diff 22a2db95 30b96fa0 | grep -c '^[+-].*auditor'`
gives 182. The package was re-validated after the auditor removal: plan and preflight both ok.
