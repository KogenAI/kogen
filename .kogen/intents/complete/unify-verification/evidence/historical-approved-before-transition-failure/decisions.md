# Decisions and provenance

- Initial input: local follow-up 12-stage-aware-rework-budgets.md described the exhausted Build and proposed progress-sensitive allowance, explicitly leaving the algorithm unsettled.
- The Shaper then prescribed allowing two Check failures, stopping on the third, resetting after a pass, and independently stopping on the third Review failure. The assistant confirmed two different reset rules.
- The Shaper explicitly asked whether check and live share a counter; the agreed explanation was one verification counter reset only when both pass.
- The Shaper challenged the old ownership split and proposed check followed by live in Stop. The final presented plan generalized this to the Intent's ordered targets, first-failure short circuit, third-failure termination, and separate bounded Review rework. This supersedes the initial one-time milestone-reset proposal and the previous split-owner contract for new-controller runs.
- The Shaper explicitly instructed: “Ok, let's go. Finish shaping this. I approve.” This approves the presented unified-loop scope and two-counter policy in this conversation; it does not authorize implementation during shaping.
- Later investigation exposed invalid handoffs. The Shaper challenged why these occur, without selecting a new policy. The controller explained model-generated protocol failures and withdrew the proposed expansion: preserve existing bounded outer-resumption handling. This is preservation from current Build.rework/4 and validate_handoff/6, not an invented third allowance or a claim that the Shaper chose one of the offered options.
- Engineering details derived from source: retain outer_resumptions for outer repairs; explicitly configure verification_retries=2 using existing required-field validation conventions; retain legacy-controller compatibility for the first self-build; extend Stop's envelope to accommodate the already maintained live envelopes; snapshot target evidence before any continuation. These implement/preserve the agreed behavior and grant no new product scope.

Original id, baseline and shaping provenance remain unchanged. Historical initial Draft files are retained under evidence/historical-initial-draft/. Current status is owned by intent.yaml; the earlier approval is preserved as historical metadata after reopening.

- The Shaper subsequently asked what could enforce handoff formatting. The controller identified schema-constrained output (already used by Review) and explained that semantic validation remains necessary. This explanatory exchange did not request or approve adding Developer output-schema migration to this Intent.

- Subsequent same-conversation naming instruction: the Shaper requested the shorter name “Unify verification” and a matching slug. Title and active directory are renamed to Unify verification / unify-verification. Identity, original baseline/provenance, agreed behavior and approval remain unchanged. Historical evidence retains the original slug as observed.

## Reopened after handoff completion

The Shaper reported “ok the handoffs is done / we can now shape unification”. This reopens the same Intent for reconciliation, not implementation or renewed approval. Identity, slug and original shaping provenance are preserved; the previous baseline and approval are retained under evidence/historical-approved-before-handoffs/ and in metadata. The active shaped-against head advances to c1c9d13747d7287a7e23f02aca02d67f0467b010, the completed handoff commit reported by the Shaper and verified locally.

The completed handoff package records the explicit Shaper answer “Keep the existing budget (recommended)”. Its accepted source enforces the schema on fresh/resumed Developer calls and preserves shared outer handling of settled structural/semantic failures. This supersedes the older uncertainty in this file; that uncertainty remains historical provenance.

New source-bound inspection and native probes establish that structured final output remains available and semantically acceptable after the third Stop failure terminates the invocation. The revised Draft makes terminal verification settlement take priority over both handoff success and structured-output correction, while preserving all completed handoff guardrails. This resolves engineering integration within the already selected behavior, with no new product scope.

## Current approval bookkeeping

After reviewing the reconciled package, the Shaper explicitly replied “approve”. Current approval is maintained in intent.yaml. Earlier statements about reopening without renewed approval describe historical Draft state; they do not describe the current package. Agreed requirements, identity, original provenance and historical evidence are preserved.

## Draft repair after failed Build

The Shaper supplied the failed run and asked “Fix Intent?”. This authorizes repairing the Draft, not implementation, an extra resumption, or approval of revisions. The accepted baseline and original shaping identity remain unchanged; the prior approved package is preserved under evidence/historical-approved-before-failed-build/.

The contract already prohibited resets from corrupt state and post-exhaustion dispatch. Source-bound execution of the stopped Candidate reproduced both counter erasure and an extra dispatch even with intact exhausted state. The revised contract makes pre-dispatch admission and initialized-state ownership explicit, requires concrete real-hook mutation/replay controls with a passing-repair counterpart, and preserves the receipt timestamp consumed by the actual live route. These are evidence and preservation repairs within the selected scope, not new retry policy.

The prior current-approval bookkeeping section above is historical. The active status is Draft in intent.yaml until the Shaper explicitly approves this revision.

## Accepted bounded shaping-process addition

After the controller explained the shaping gap, the Shaper asked to fix the shaping process within this Intent. The controller proposed explicit state/action order, observable negative controls, real consumer tracing and evidence-level distinctions, with focused shaping regressions. The Shaper replied “Yes, please.” This accepts that scoped addition; it is not approval of the resulting revised package or authority to change production files during shaping.

Inspection found that the accepted shaping quality section already asks for outcome walkthroughs, probes and consumer tracing, while its focused prompt test mainly asserts instruction text. The existing five-case evaluation correctly separates native capture integrity from independent semantic Review. Extend that maintained mechanism with only one flawed/complete guardrail pair; do not invent a semantic keyword validator or broader shaping framework. The current dirty shaping prompt differs from HEAD only in previously attempted budget wording, which is unaccepted Candidate work.

## Approval of the expanded contract

The Shaper explicitly approved the current revised package after the failed-Build repairs and bounded shaping-process addition. Current approval is maintained in intent.yaml. Earlier Draft/pending-approval statements in this chronological decision history describe their original stage, not current status. Requirements, identity, original provenance and evidence are preserved.
