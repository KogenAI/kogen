# Follow-up: Enforce structured Developer handoffs

Status: unshaped, unapproved shaping input. Requested by the Shaper on 2026-09-14 during the Unify verification conversation. This file creates no Intent identity, approval, implementation authority, or Build.

## Problem and desired outcome

Kogen should provide guardrails that prevent avoidable protocol errors, rather than merely detect malformed model output and consume repair allowance. The Developer's final handoff currently relies on generated text following instructions. Passing application tests does not ensure that this final response has the required structure or matches the active Build contract.

The human explicitly separated handoff work from unified verification and budgets, then asked to save this follow-up. The desired outcome is a structurally constrained Developer handoff that Kogen validates before independent Review, with a clear distinction between malformed structure, semantically invalid claims, and interrupted provider execution.

Use the existing Reviewer schema-constrained output route as the starting mechanism to investigate. Do not promise that every invocation succeeds or that a schema makes claims true. On successful constrained completion, enforce the supported structural contract; runtime checks still verify attempt binding, exact scenario/risk/finding coverage, cited files and evidence authority. Failure must never become acceptance.

## Source to inspect

Read repository README.md first, then the current source. At inspected HEAD `2890d86f16c8819cfad12cbd98dbbdc8ee068b1c`:

- `lib/kogen/harness.ex`: `developer_args/3`, `launch_developer/4`, `resume_developer/5`, `run_turn/3`, and `parse_turn`; Developer launch/resume currently have no output-schema argument. `launch_reviewer/3` creates a private schema/output directory, passes `--output-schema` and `--output-last-message`, parses the result, then removes owned temporary files.
- `lib/kogen/build/contract.ex`: `handoff/4` requires exact top-level keys `attempt_token`, `scenarios`, `risks`, and `findings`, then checks token binding and collection contents. Inspect all collection and reference validators, not just JSON parsing.
- `lib/kogen/build.ex`: `begin_attempt`, `validate_handoff`, reference snapshotting and `rework`; malformed handoffs currently share the outer-resumption budget with Review rework.
- `priv/kogen/prompts/developer.md`, `test/kogen/harness_args_test.exs`, `test/kogen/harness_verdict_test.exs`, public fake/native lifecycle fixtures, and scenario response helpers. Discover all real launch/resume consumers and fixture assumptions before choosing the contract.

The locally installed CLI observed during the preceding shaping investigation was 0.154.0; README still names 0.153.4 as its verification target. Verify the actual CLI and supported schema behavior on both fresh Developer launch and exact-session resume. Prior Reviewer usage is source evidence, not proof of an unexercised Developer/Stop/resume combination.

## Bounded investigation and shaping choices

Aim for one small Build about the handoff producer/consumer boundary. Investigate schema constraints supported by the actual client/provider, including whether the selected attempt token and exact collection shape can be encoded without inventing unsupported JSON Schema behavior. Keep the existing runtime semantic validator as authority.

Use owned disposable paths and a bounded real probe with controls: fresh constrained output, exact-session resume with a new attempt token, Stop-blocked continuation, malformed or missing provider output, and stale output from a previous invocation. First rehearse deterministic orchestration; preserve source, argv, schema, inputs, output, results and limitations. Do not substitute a mock's valid JSON for native enforcement evidence.

Trace schema/output file ownership from creation through invocation, Stop continuation, outer resume, validation, evidence retention and cleanup. A new invocation must not consume a previous output file. Capture needed evidence before removing temporary source files. Preserve exact Developer continuity and fresh independent Review after actual rework.

The consequential question still to shape is how recoverable semantic handoff errors are corrected without treating them as application/Review failures or permitting an endless loop. Prefer preventing constraints that can be enforced and giving actionable correction for the rest. Do not silently add a retry pool, waive semantic checks, or guarantee success for interrupted invocations. Decide this from inspected capabilities and the human's guardrail objective; proposed mechanisms here are not accepted policy.

## Required outcomes and controls

- Ordinary fresh and resumed Developer routes produce the required structure through a verified constraint mechanism, rather than prompt compliance alone.
- Current token, complete scenario/risk/open-finding coverage, useful claims and existing evidence references are validated before Review.
- Structurally valid but stale or semantically wrong handoffs cannot pass; provider failures and missing/truncated output cannot be mistaken for valid completion.
- A Stop-blocked continuation can reach a valid final handoff without losing the original Developer session or accepting stale gate evidence.
- File lifetime and cleanup cannot erase evidence needed for independent Review or cause an invocation to reuse earlier output.
- Existing gate ownership, Candidate bindings, guardrails, finding closure and publication safety remain intact.

Use Make targets actually declared when shaping. The current targets are `check` and `live`; affected fresh/resumed native Developer workflow requires native evidence as well as deterministic fixtures. The outer fixture driver owns ephemeral session and callback observations and must retain an inspectable receipt; Review assesses the retained contract, Candidate and owned evidence.

## Relationship and sequencing

[Unify verification](../../../intents/approved/unify-verification/README.md) is the separately approved Intent for one Stop-driven gate sequence and verification/outer-rework counters. It excludes schema-constrained Developer output and preserves existing malformed-handoff handling.

Controller recommendation, not an accepted schedule: shape and build this handoff guardrail first, then revisit Unify verification against the resulting accepted HEAD. If handoff correction semantics change here, explicitly reconcile the approved verification package's preservation clause before its Build; do not silently overwrite its baseline or requirements. There is no demonstrated hard dependency requiring this order.

Do not bundle gate relocation, quality budget redesign, parser/transport recovery, account authentication, or stopped-Build continuation into this follow-up. Approval of Unify verification does not approve this work.
