# Build o-DlRi_iHnqIwmxfcCz-obe0 failed (2026-09-25)

Candidate stashed as `cross-harness-candidate-2026-09-25b` (SHA 2294e64a1a).
- Cycle 1: check failed (formatting); fixed.
- Cycle 2: check passed, **live-native passed**; live-reviewer-rework failed in 0.3 s in the new
  Codex login preflight (install.py was not found from the isolated test code copy). The
  Developer fixed it with compile-time source paths for install.py and native_settings.py.
- Cycle 3: check passed, **live-native passed**. live-reviewer-rework **ran the whole hybrid
  lifecycle in 433 s** (Claude Developer, Codex Reviewer rework, fresh Codex Reviewer), then
  failed in LiveReworkAudit.audit_retained!/1: "bound record version sidecar unavailable:
  .kogen/runtime/scenario-tracking/cGvDE8dV…/record-versions/92ab9ab7….json".

Root cause (a latent defect from Intent #1): the Codex Reviewer cited its own record, so #1
wrote a record-version sidecar. The fixture's preserve/3 copies only record.json into the log
directory, and Evidence.resolve/2 looks for the sidecar at its checkout-relative path. The
fixture was then deleted. #1's own live runs used Claude Reviewers, which did not cite the
record, so no sidecar existed there.

Fix: new scenario `retained-evidence-with-record-sidecars`, which resolves sidecars next to
the record and copies `record-versions/` on preserve, with an offline regression. Retry
reuses the stash: restore it, then add the fix.
