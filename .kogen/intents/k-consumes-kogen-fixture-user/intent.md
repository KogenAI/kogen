# Separate fixture identity from Intent titles

Slug: k-consumes-kogen-fixture-user
Model: not applicable — this is a test-fixture and assertion correction, not a state-machine change
Acceptance:
- .kogen/intents/k-consumes-kogen-fixture-user/acceptance.feature
- features/steps/k-consumes-kogen-fixture-user__suite.js

Fix the consumer first in cli/consumes/kogen-shaping. Set its fixture Git user.name to "Kogen Test Owner", retaining the Intent title "Fixture intent" and the existing direct configuration and title literals so the fixture remains inspectable. No fixture Intent title may contain the fixture Git user.name. Update identity-dependent expectations accordingly. Keep the coordinator's owner-authored-title rule intact. Do not change dependency pins or production behavior.

In TestPreflightJSONShowsTheCheckoutAndTheBlockers, assert the blocker under test by class/reason membership (intent/approval_changed before approval), rather than requiring a singleton array or its position. Preserve the checkout JSON, exit/status, successful approval, and post-approval ready/no-blocker guarantees. Additional lint failures concerning this fixture must still surface through readiness/approval; do not suppress fixture defects. Preserve useful checks unrelated to blocker cardinality.

## Decisions
- Use the supplied example identity "Kogen Test Owner" with the title unchanged. (source: request)
- Exercise the current pin and coordinator 91d0a32, the supplied main baseline, using disposable alternate module files, without upgrading committed pins. (source: request)

## Source comparison
- Addressed: request Problem and Need, including helper_test.go's "Fixture"/"Fixture intent" collision and preflight_test.go's singleton blocker assertion, by the fixture identity and membership rules above and separate regression scenarios in acceptance.feature.
- Addressed: both Acceptance bullets by the full consumes-suite matrix and direct fixture identity/title observation. The assertion-specific scenario checks removal of singleton/index-zero coupling while retaining approval_changed; the full suite checks the resulting behavior.
- Addressed: coordinator 91d0a32 or later is represented by exact v0.0.0-20261103212139-91d0a325d982; today's pin remains the committed cli/go.mod selection. The reported adoption window 20261104T002038Z and shaping 5cf70c2 are historical context, not versions to upgrade.
- Omitted: no requested behavior. Superseded: exact blocker cardinality/order before approval. No coordinator rule changes or protected module edits are authorized.

## Tests
- Fixture titles exclude their actual Git user.name: direct fixture-literal regression observation and add a local Go regression assertion using newFx and fixture title content (regression)
- Preflight checks the relevant approval blocker without coupling to unrelated blocker count or order: update TestPreflightJSONShowsTheCheckoutAndTheBlockers and observe removal of its singleton/index-zero assertions (regression)
- Consumes compatibility with today's pin and coordinator 91d0a32: run the whole existing kogen-shaping consumes suite against both selections (integration)

## Feasibility
- The pinned consumes suite passed unchanged; resolving 91d0a32 yielded v0.0.0-20261103212139-91d0a325d982. (probe 1: exit 0, 21.9 s)
- An alternate .mod/.sum outside the checkout successfully exercised coordinator 91d0a32 and reproduced invalid_package for the Git-user/title collision, plus resulting Refine failures. (probe 2: exit 1, 9.0 s)
- Documentation search returned Go sources; fetching https://go.dev/ref/mod at -modfile returned an untrusted response, not relied on as authority. Alternate-module behavior was established locally instead.
- evidence: {"id":"fixture-observer","kind":"observer","inputs":["cli/consumes/kogen-shaping/helper_test.go","cli/consumes/kogen-shaping/preflight_test.go"],"observers":["features/steps/k-consumes-kogen-fixture-user__suite.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k-consumes-kogen-fixture-user__suite.js --control-good","exit":0,"output":"observer failures: 0\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k-consumes-kogen-fixture-user__suite.js --control-bad","exit":1,"output":"observer failures: 2\n"}]}
