> Execution starting point: [recovery-start.md](recovery-start.md).

> Current approved revision: read [approval-transition-amendment.md](approval-transition-amendment.md) first. Earlier receipts remain historical evidence.

# Improve shaping quality with five compact live cases

Status: Amended package explicitly approved. Read amendment.md first and evidence/amendment-approval.md; the original approval is historical.

Read [the amendment](amendment.md), this contract, [decisions](decisions.md), [evaluation](evaluation.md),
[scenarios](scenarios.yaml), [risks](risks.yaml), [questions](questions.md) and
[fixture facts](fixtures/facts.json). [Evidence](evidence/README.md) records current
investigation; [references](references.yaml) records provenance rather than extra scope.

## Outcome

Shaping should produce a contract that supports a usable outcome and autonomous Build
and Review. It must investigate discoverable technical uncertainty without waiting
for permission, preserve supplied decisions, and ask only consequential unanswered
product, UX, policy or authority questions. An unnecessary confirmation that stalls
progress is a failure even if later answers rescue the final Draft.

Improve the existing conversation, not add a separate ceremony. Apply the following
to fresh Shaping and continuation through the maintained role prompts:

1. Read the brief, repository context and accepted decisions. Trace the intended
   starting conditions, actors, assets and authority through concrete actions to a
   usable result. Consider failures and recovery where this feature makes them
   consequential. Distinguish the actual problem from a suggested mechanism.
2. Challenge the proposed contract with a plausible implementation that passes its
   checks but fails the outcome. Repair the acceptance conditions or expose a real
   human choice. Pair material rejection cases with preservation of legitimate use.
   Do not silently narrow the audience, invent compatibility restrictions, or hide
   essential work in non-goals.
3. Investigate a material technical assumption autonomously within authorized scope.
   State the uncertainty and decision it could affect; use a bounded real probe and
   an appropriate disconfirming/preservation control when source inspection alone
   cannot establish behavior. Use disposable owned paths, preserve results and
   limits, and connect findings to the Draft. A plan to probe is not execution.
   Keep production implementation outside Shaping; propagate that boundary to helpers.
4. Preserve sufficient current source-bound evidence. Inspect a prior-success claim's
   actual source, inputs and available setup before relying on it; a different passing
   mock cannot repair missing credentials or a removed temporary dependency. Do not
   repeat an unchanged successful probe just to obtain a new receipt. Failed or
   invalid experiments remain evidence with clear limitations, not readiness claims.
5. Resolve ordinary engineering, file-handling and verification choices through
   inspection and maintained conventions. Do not ask permission for an already
   authorized bounded probe, reconfirm supplied scope, or send an irrelevant lifecycle
   questionnaire. Inspect consequential ownership dimensions; supplied facts satisfy
   them. Ask only about remaining material choices or genuinely missing authority,
   with a concrete consequence, while independent work continues. Do not invent a
   protected-seed ownership transition. Shared configured delegation remains selective;
   no required helper quota or extra review agent.
6. Shape credible verification before approval: realistic starting state, actual
   consumer, observable success, wrong-result controls, prerequisites, authority,
   lifetime and cleanup. Choose methods for their proof and maintenance/cost limits,
   not by asking the human to choose routine offline versus paid test mechanics.
   Select targets by new behavior and regression exposure in existing workflows, not
   by whether test files were added or edited. Existing live-only behavior affected
   by changed production code can require live verification with no live-test diff.
   Where changed execution boundaries matter, trace the real producer-to-consumer
   route and rehearse deterministic orchestration before paid execution. Do not
   substitute component assertions or synthetic integrations for the unexercised route.
7. Persist a compact walkthrough/challenge in INTENT.md, accepted choices with
   provenance in decisions.md, unresolved choices in questions.md and relevant linked
   scenarios/risks/evidence. Partial answers settle only explicitly selected or
   necessarily entailed behavior. Before package approval, resolve material product
   choices with the human or agree a narrower complete outcome; do not leave those
   decisions to the Developer or Reviewer. Ordinary implementation discretion remains.
8. Continuation reads current saved state and acts on direction already supplied.
   Ask where to continue only when direction is missing. Preserve original identity,
   baseline, evidence and shaping provenance; record the visit through existing fields.
   Historical approval, investigation authorization, a partial answer and silence are
   never approval in this conversation. Preserve the existing explicit approval move.

Reconcile existing blanket wording that says to ask about every lifecycle dimension
or always ask where to continue with these rules. Do not merely append contradictory
new paragraphs. The root README summarizes and links the maintained owners.

## Appetite and proof

One Developer conversation with the configured two outer resumptions. Production
changes are confined to Shaping/continuation instructions and navigation. Five compact
live cases plus their offline rehearsal test this behavior: two flawed/complete CLI
pairs and one independent frozen-seed continuation. [evaluation.md](evaluation.md)
owns the exact proof. No extra live campaign or model grader.

Use existing `check` and `live`. The Stop hook and outer Build retain their gate
ownership. Independent Review must assess the real conversation sequence and saved
contracts; neither a deterministic validator nor a live exit code alone proves quality.

## Accepted prerequisite and baseline

The Shaper reported 06 complete and directed continuation on 2026-09-13. Accepted HEAD
56af370a39719ed6aca378c1974bea918800049d now supplies target artifact delivery/retention;
6072c0f5 supplies independent live scheduling groundwork. This Draft uses those
interfaces rather than implementing them again. Original shaped_against and shaping
metadata remain historical facts; intent.yaml separately records the reassessed HEAD.
The bounded aggregation probe verifies five simultaneous producers feeding one
manifest through current isolated dispatch and the real evidence consumer.

## Non-goals

No charting/GUI, column mapping, booking writes, cancellation, real provider OAuth,
application implementation, installer or new Kogen public command. No generic benchmark
platform, paid grader, scheduler service, telemetry/storage redesign, target-evidence
engine revision, shared execution-policy/profile changes, new schema or approval gate.
Only the two named cleanup-test files are added for the bounded readiness correction in amendment.md. No suite-wide concurrency redesign, retries inside failed evaluation cases, increased
Build budget, production shaping deadline, historical evidence rewrite or bulk import
of the old Candidate. Five cases provide bounded regression evidence, not universal
quality or cost guarantees.
