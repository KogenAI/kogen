**Read-only re-audit:** no files changed; no build or live tests run. The reference patch was inspected as reference material.

| Earlier finding | Status |
|---|---|
| Sol 1 — timeout rule | **Not resolved:** the 240 s limit is consistent, but “if a typical run still fits” leaves the retry cutoff undefined ([scenarios.yaml:191](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/scenarios.yaml:191)). |
| Sol 2 — unverified live-owner edits | **Resolved:** those edits and the default flip are deferred. |
| Sol 3 — default-route readiness effects | **Resolved:** the default remains `claude`; hybrid readiness is specified separately. |
| Sol 4 — omitted catalog test | **Resolved:** it is in the scenario paths and proof. |
| Sol 5 — wrong default implementation could pass | **Resolved:** this Build no longer changes the default. |
| Sol 6 — incomplete frozen-matrix proof | **Not resolved:** the mutation proof names Developer, Reviewer and Expert, but does not exercise auditor or helper assignments ([scenarios.yaml:101](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/scenarios.yaml:101), [126](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/scenarios.yaml:126)). |
| Sol 7 — feasibility left to Build | **Not resolved:** the proposed admission probe cannot run on the specified main as written; see below. |
| Sol 8 — post-#1 validation receipt | **Not resolved yet:** it is now an explicit admission gate, but #1 has not landed on the inspected `2909f557` baseline. |
| Sol 9 — clean-route wording | **Resolved:** auditor resolution and readiness are explained. |
| Sol 10 — catalog proof | **Resolved:** the direct catalog test is selected and controller files are declared byte-frozen. |
| Astra 1–3 — default-route live proof | **Resolved:** the default flip and affected live-owner edits are deferred. |
| Astra 4 — launch contract tests | **Resolved:** both named tests are selected and declared affected. |
| Astra 5 — #1 fixture ownership | **Resolved:** #1 explicitly owns the fixture and its test. |
| Astra 6 — mid-Build timeout risk | **Not resolved:** the proposed pre-Build probe is not executable as specified. |
| Astra 7 — retry across Stop cycles | **Resolved:** retry is specified per test invocation; Stop cycles remain controller-owned. |

**New blocking problems introduced by the revision**

1. The admission gate requires a hybrid `live-reviewer-rework` probe on post-#1 **main before this Build**, yet the hybrid route and fixture pin are delivered *by this Build* ([risks.yaml:43](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/risks.yaml:43), [INTENT.md:97](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/INTENT.md:97)). **Fix:** specify a disposable, post-#1 probe Candidate containing the minimal hybrid route and fixture changes, or replace the impossible gate with an executable pre-Build criterion. Make the gate mandatory if it controls admission.

2. The revision requires preservation of **five** #1 controls, but its post-#1 gate checks only the packet, output limit and fixture root; the scenario proof likewise does not assert metadata-only citations or superseded-objection handling, even though this Build changes `build.ex` ([INTENT.md:41](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/INTENT.md:41), [risks.yaml:82](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/risks.yaml:82), [scenarios.yaml:124](/private/tmp/claude-501/kogen-shape-cross-harness/kogen/.kogen/intents/drafts/cross-harness-adversarial-roles/scenarios.yaml:124)). **Fix:** add targeted post-#1 assertions and offline proof for those two behaviors, including a passing later Stop cycle that supersedes an earlier objection.