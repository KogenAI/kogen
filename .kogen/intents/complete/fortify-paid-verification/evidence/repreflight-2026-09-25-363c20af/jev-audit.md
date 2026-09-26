# Jev audit (shaping-audit-v1, jev-1.13.0), advisory

Package: `.kogen/intents/drafts/fortify-paid-verification`. Requests: 258. Input tokens: 323634 (about $0.0136).

| flag | scenario | text | answer |
|---|---|---|---|
| hard-rule-risk | controller-runs-proof-selectors | Its base checks are skipped, and the report labels it `unproven-on-base`. | {"weaken": 0.79} |
| hard-rule-risk | no-special-gate-target | Admission no longer requires a `check` target. | {"weaken": 0.91} |
| hard-rule-risk | stop-free-compatibility-fixture | Its evidence no longer requires `hook_receipt`, `checks` or `checks_before_resume`, and its prompts no longer tell the model that a Stop hook settles a Check. | {"weaken": 0.81} |
| hard-rule-risk | stop-route-bootstrap-only | The no-context check-and-block mode and the `KOGEN_TRACKING_CONTEXT` path are gone. | {"weaken": 0.79} |
| then-without-described-proof | controller-runs-proof-selectors | It is reused while the overlay digest is unchanged. | not_described 0.85 |
| then-without-described-proof | controller-runs-proof-selectors | A catalog without the integrity fields labels every scenario `integrity-not-configured`. | not_described 0.98 |
| then-without-described-proof | controller-runs-proof-selectors | Non-file selectors (rehearsal ids, root `.txt` fixtures, `scripts/check` files) stay existence-checked, and are labelled as such. | not_described 0.90 |
| then-without-described-proof | no-special-gate-target | Receipts form one uniform list, with no separate `check` field in the tracking record, handoff report or review packet. | not_described 0.81 |
| then-without-described-proof | no-special-gate-target | Maintained prompts and docs describe `verified_by` as the complete, explicit list. | not_described 0.98 |
| then-without-described-proof | offline-first-target-selection | Deterministic orchestration is proved offline, including through a complete fake-harness run. | not_described 0.95 |
| then-without-described-proof | offline-first-target-selection | Kogen's orchestration (controller, plan, receipts, tracking, reports, Jev plumbing, guards and catalog rules) is offline-only. | not_described 0.97 |
| then-without-described-proof | offline-first-target-selection | An Intent that edits a live test's owner file selects that test's target in the same Intent, because an edited live test that never runs is unverified. | not_described 0.98 |
| then-without-described-proof | stop-route-bootstrap-only | `Makefile` and `priv/kogen/verification_targets.yaml` stay byte-identical to main, because main's controller stops a Build whose catalog changed after admission | not_described 0.90 |
| then-without-described-proof | verification-surface-ledger | If the Developer objects to the contract, the existing cannot-comply path returns the Intent to Shaping. | not_described 1.00 |
| weak-wrong-result-maybe-not-caught | self-hosting-two-step-guidance | it describes main's pre-Intent freeze instead of the controller this Intent ships | choice=none 0.40, noul=0.57 |
| weak-wrong-result-maybe-not-caught | stop-free-compatibility-fixture | provider retries or timeouts are added to Kogen core or config | choice=e1 0.84, noul=0.59 |
| weak-wrong-result-maybe-not-caught | verification-surface-ledger | ledger dispositions are folded into the finding `dispositions` | choice=none 0.31, noul=0.57 |
