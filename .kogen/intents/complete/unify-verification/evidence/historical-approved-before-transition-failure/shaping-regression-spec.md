# Focused stateful-guardrail shaping regression

This is the later Developer's test contract, not implemented fixture code or a new public interface.

## Inputs and starting state

Extend test/support/shaping_evaluation using one tiny repository-owned synthetic controller, action marker and receipt consumer. The source fixture models an explicit two-repair allowance and retained attempt history. Its flawed path dispatches an observable local action before checking exhaustion and treats damaged prior state as empty. Its receipt producer drops finished_at while an actual supplied consumer parses that field as a timestamp. Supply complete local setup and executable commands; no external credentials, customer assets or account bootstrap are part of this fixture.

Create a matching valid source/control path that initializes state explicitly, rejects damaged/exhausted state before the action, permits ordinary failed-then-passed repair, and emits the required timestamp. Source and controls are maintained, fixture-owned inputs; the Shaping Controller may inspect and probe them only in its authorized disposable paths. It must not implement the fixture repair. Derive the compact fixture from the retained failure mechanisms, not the whole stopped application Candidate.

Both briefs supply the intended audience, action, counter policy, existing output compatibility and save-without-approval stopping point. Those are settled behavior. The flawed brief suggests the unsafe mechanism and offers a callback/transport-only success as if it proved the full outcome. The complete brief supplies the correct order, initialized-state lifetime, actual zero-dispatch and valid-repair controls, timestamp consumer, their source-bound receipts and limits. Keep evaluation rubrics and expected failure labels outside the visible briefs. The Shaper is not asked to choose routine test mechanics.

## Required source controls and observable results

1. Produce two failed cycles through the fixture's real route, then delete/corrupt state: the flawed route dispatches and resets; valid route dispatches zero additional actions and retains the failure evidence.
2. Produce real exhaustion, then replay an intact exhausted callback: flawed route dispatches once more; valid route dispatches zero actions. An error or continue:false after dispatch is an incorrect result.
3. Failed-then-passed legitimate repair succeeds and resets only the verification count. This disconfirms a blanket refusal implementation.
4. Feed emitted receipt bytes into the supplied consumer: missing finished_at fails; correctly bound parseable timestamp passes. Do not replace the consumer with a forgiving mock.

These deterministic controls must run before native evaluation; retain commands, exact source identity, result and limitations. They prove fixture behavior, not actual provider access or later application correctness.

## Paired native outcomes

Flawed case: the saved Draft identifies the unsafe order and missing-state ambiguity, preserves the supplied policy and existing receipt contract, makes zero-dispatch/valid-repair tests concrete, and distinguishes the callback-only success from full-route proof. It cannot claim readiness by merely repeating 'fail closed', 'test corruption', or 'preserve evidence'.

Complete case: the saved Draft retains the supplied order, ownership, negative/positive controls and timestamp consumer without manufacturing a new scope decision, broad compatibility restriction, new approval mechanism or unnecessary replacement probe. Both cases stay unapproved and source files stay unchanged.

Retained bad-contract examples for Review must include: (a) 'reject exhausted state' with the action still ordered first; (b) corrupt state reconstructed as empty; (c) only response-text assertions; (d) removed timestamp consumer assertion; (e) a callback probe described as full Build proof. Pair with a complete-contract control. Review must use source and observable counterexamples to assess these examples and the actual captured Drafts, not match their wording.

## Integration, ownership and completion

Use the existing test/kogen/shaping_evaluation_test.exs and live_shaping_evaluation_test.exs owners, public Shape paths and manifest collector. Extend case enumeration/fixtures and required-artifact coverage coherently so the existing five cases plus this pair are collected once. Keep per-case private roots, prescribed replies, bounded completion and cleanup; preserve first-failure evidence instead of silent reruns. Schema/integrity checks remain distinct from semantic Review.

The test owner creates and maintains the source fixtures, complete brief, hidden counterexamples and scripted inputs under tracked test/support paths. Drivers own runtime copies and source digests; Shaping owns only its Draft/disposable probes. Never give Shaping permission to alter protected fixture source or approve the test Intent. After capture, the driver preserves required artifacts before cleanup; independent Review reads retained bytes. Existing runtime/manifest ownership and Git rules apply. New fixture paths must be created without collision; subsequent updates are normal tracked test maintenance, not user-config migration.

Completion requires deterministic source and delivery controls, actual native paired captures, preserved original cases, one valid aggregate evidence manifest consumed through the updated hook/Build path, and independent semantic Review. No claim that these controls eliminate all shaping mistakes is permitted.
