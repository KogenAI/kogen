# Parallelize independent live cases and consolidate primitive probes

## Problem and outcome

At accepted baseline d8daec8a, private fixture isolation is available, but the
connected public lifecycle and independent Reviewer-rework fixture are tests in
one ExUnit module and therefore run sequentially. Another module spends three
paid invocations on primitives already exercised by these real lifecycle routes.

Make independent existing live work eligible to overlap through normal ExUnit
scheduling, and eliminate those three standalone invocations only after their
unique assertions are enforced on current lifecycle output. Preserve causal
ordering inside each lifecycle. No public command, configuration or product UX
changes are proposed.

## One Build

1. Separate the public Shape-to-Commit and Build-only Reviewer-rework cases into
   independently scheduled async modules, preserving the existing private fixture,
   writable dependency, process cleanup, retained evidence and profile audits.
   Semantic Review, native-helper and cold-offline cases remain independent.
   Respect available scheduler capacity; do not add an unbounded scheduler.
2. Add a test-support native receipt audit reached by the retained live cases.
   Bind streams to the actual expected session identities and Reviewer responses;
   require successful `turn.completed` settlement with a usage map for each
   required invocation. Prove exact Developer resume and distinct Reviewer
   sessions. Validate the actual structured Reviewer schema and identity bindings,
   using existing contract validation where suitable. An unrelated successful
   stream, missing completion, malformed response or failed provider event cannot
   satisfy a required invocation.
3. Map every assertion of the old primitive test to a retained live assertion and
   offline negative control, then delete only the redundant three-call primitive
   test. Do not delete it before replacement controls exist. Keep its profile
   and outer-resumption configuration checks wherever still necessary.
4. Add offline orchestration proof using the actual isolated-process dispatcher
   and ExUnit module scheduling, with a rendezvous that fails if independent
   work is serialized. Exercise ordered dependent work, distinct outputs,
   failure propagation and owned cleanup. The lightweight shaping probe is not
   this acceptance regression. Include a control on the live selection/module
   layout so a generic concurrency test cannot pass while live cases remain
   serial. No test may invoke provider-backed cases during `check`.
5. Update maintained live-suite documentation and capture concise comparison
   evidence through existing runtime/Complete conventions. Report whole-suite
   elapsed time and observed provider invocation/usage totals when available,
   including native descendants. Missing usage remains unavailable. Cached
   input is a subset. Do not add a telemetry system or paid benchmark campaign.

## Proof owners that must survive

| Existing proof | Owner after consolidation |
| --- | --- |
| Fresh Shape, continuation, explicit fixture approval, same Intent identity, public Build and Commit | Connected public lifecycle |
| Actual failed Stop Check then passed Check in the same Developer session, zero outer resumptions | Connected public lifecycle |
| Actionable first Review, same Developer resumed, ordered new Check, fresh accepting Review, exact final bytes and commit provenance | Separate Build-only rework lifecycle |
| `turn.completed`, usage map, exact native session and schema assertions from the three-call probe | Native receipt audit called by retained lifecycle owners, with offline negative controls |
| Independent rejection of semantic defects and acceptance of corrected counterpart | Existing two-call semantic Review case |
| Actual native child execution/profile binding and receipt fidelity | Existing native-helper case |
| Full cold offline gate, empty private cache, private writable dependencies, provider denial | Existing cold-offline case |
| Malformed/error Harness controls and lifecycle integrity negatives | Existing offline tests, plus focused new audit/orchestration controls |

A valid child audit is insufficient if the actual live test omits it or ignores
its failure. A composed offline negative must corrupt required native evidence
and demonstrate failure through the same audit invocation used by the retained
live owner. `make live` must propagate case failure as nonzero. Keep the current
raw evidence ownership; target manifests and retention redesign belong elsewhere.

## Acceptance and limits

The Stop-owned `check` runs offline controls; outer-owned `live` runs the complete
remaining suite once per normal Build attempt. Existing gate ownership, fresh
independent Review, same-Developer rework and two outer resumptions remain intact.
A failed run is retained and explained, never silently retried into a passing
measurement. Historical streams are structural probe inputs only.

Report the structural saving (three removed standalone invocations) separately
from measured end-to-end improvement. Compare measurements only with stated
baseline, environment and cache conditions; if comparable baseline usage or time
is unavailable, say so. No hard duration or percentage speedup is an acceptance
threshold. Provider contention can offset wall-clock gains.

## Non-goals

No proposal-08 shaping evaluation cases or shaping prompt changes; no production
controller, configuration, hook or gate changes; no merged public/rework lifecycle;
no removed semantic or native-helper proof; no result cache, gate-result reuse,
changed-source selection, retry increase, fallback provider, new public scheduler,
retention service or benchmark campaign. Do not import the historical broad
Candidate. Other obligations remain with their original proposals.

## Provenance and ownership

The supplied 07 proposal and original suite-optimization decisions support this
slice. The original broad scope is superseded by the supplied serial plan, but its
requirements to preserve proof and move assertions before deleting paid work are
retained here. The current accepted predecessor, not that historical Candidate,
is the implementation baseline. This Draft transfers only the scope listed above
upon explicit approval; it does not approve or modify the broad original Draft.

Routine source/fixture ownership follows existing conventions as recorded in
risks.yaml. No new persistent user data or ownership transition is introduced.
The supplied follow-up explicitly directs preserving existing files and handling
ordinary fixture cleanup without a new lifecycle questionnaire.
